#!/usr/bin/env bash
# codex-run.sh — deterministic runner for the codex-worker contract (v4.0-d).
# v4.0-d (2026-07-14): spawn-to-record window CLOSED — the codex child records
# its own identity ($BASHPID) before exec'ing codex, so no ordering of leader
# death can strand an unrecorded live codex or double-launch past it.
# v4.0-c (2026-07-14, Stage E): security-review fixes — manifest-recorded codex
# pid identity (attach convergence when the lock died with its holder), cancel
# signalling via identity-verified group members only, OUTPUT_FILE delivery
# moved into --finalize under a per-destination lock with terminal state
# reflecting delivery, publish-last finalization (usage before terminal
# manifest), operand validation, directory fsync, legacy flag-mode CWD
# auto-create restored. EFFORT ultra REJECTED (multi-agent profile disabled
# pending re-bench 2026-07-13; give legs an explicit orchestration protocol in
# task text instead).
# Stage B2 (2026-07-13): attempt manifests, terminal finalization, lifecycle
# status/sweep/cancel commands, and cached offline binary capability probes.
# v4.0-b (2026-07-13): runner-owned request-envelope parsing via
# --parse-request/--request-file, with byte-preserved tasks and request hashes.
# v4.0-a (2026-07-13): Stage A guards — explicit CWD creation, no-clobber
# OUTPUT_FILE ownership, task/provider exit 3, and flock-backed launch dedup.
# v3.9 (2026-07-13): launch dedup — the haiku forwarder can re-run an identical
# launch command 30-60s after backgrounding the first (same-day incident: a
# stage twin ran 64 min / 45M input tokens with ZERO usage.log trace — only the
# surviving launch's poll logs ok, and both twins held workspace-write on the
# same checkout). Launches are keyed on sha256(task+directives) via flock on
# $WORKER_HOME/locks/<hash>.lock; a second identical launch while the first is
# live converges onto its scratch (returns CODEX_RUNNING + the first's poll
# path) instead of spawning. When the lock died with its holder but the codex
# child survives, the manifest-recorded codex pid identity (v4.0-c) is the
# attach fallback. Deliberate identical parallel legs must differ by a nonce
# line in the task text.
# v3.8 (2026-07-13): REVIEW uncommitted + task text auto-converts to custom
# (same uncommitted diff, caller's instructions as the review prompt) instead
# of failing the leg; base=/commit= with task text still hard-error (codex
# 0.144.0 cannot combine a custom prompt with --base/--commit).
# v3.6 (2026-07-09): default model gpt-5.5 -> gpt-5.6-sol; default effort
# medium -> high; effort enum extended to none|low|medium|high|xhigh|max|ultra
# (verified on codex 0.144.0; codex maps `ultra` -> `max` API effort + proactive
# multi_agent delegation, default ~6 threads/depth 1 — see codex 0.144.0 source).
# v3.7 (2026-07-09 audit): reject NETWORK with read-only (silent no-op before);
# read-only/review require an EXISTING --cwd (a typo no longer becomes an empty
# workspace); OUTPUT_FILE write failure is a loud CODEX_ERROR (no silent relay
# fallback); per-attempt token usage is summed across retries (no undercount);
# new --verify mode validates session ids against usage.log (unforgeable proof
# for the ungated Workflow path).
# Launch mode: reads the task text on stdin, launches codex detached, polls.
# Poll mode (--poll <scratch>): resumes polling a still-running launch.
# Recover mode (--recover <session-id>): re-emit a completed run's content +
# footers from the archive + usage.log — the mechanical fix when a relay was
# stripped or lost (never retype results from memory).
# Verify mode (--verify <id[,id...]>): print `ok`/`forged` per session id by
# checking usage.log — the orchestrator's post-fan-out proof check for Workflow
# legs, which the settings.json hooks do not gate.
# Review mode (--review uncommitted|custom|base=<branch>|commit=<sha>): runs
# codex's native review harness in an isolated CODEX_HOME; results extracted
# from session rollouts (review has no --json/-o on codex 0.144.0).
# Default output: delimited envelope block. --footer: caller-contract format
# (content + [codex-session:]/[codex-usage:] footers) for the codex-worker
# agent to return verbatim; see ~/.claude/agents/codex-worker.md.
# File relay (v3.3): every ok result is archived to
# $WORKER_HOME/results/<session>.txt (pruned after 7 days). In --footer mode,
# content larger than CODEX_RELAY_MAX bytes (default 8192 — the measured
# haiku verbatim-relay ceiling, 2026-07-07 incident) or any --output-file run
# replaces the inline content with a one-line envelope
# `[codex-final-file: <path> bytes=<n>]` that the wrapper can relay reliably.
set -u

SELF="$(exec 9>&-; cd "$(dirname "$0")" && pwd)/$(basename "$0")"
INVOCATION_PWD="$PWD"
MODEL=gpt-5.6-sol EFFORT=high SANDBOX=read-only CWD="$PWD"
NETWORK=0 MCP="" SCHEMA="" SCHEMA_FILE="" RESUME="" RETRY_SAFE=0
POLL="" BUDGET=540 FOOTER=0 REVIEW="" EXTRACT="" OUTPUT_FILE="" CREATE_CWD=0
RECOVER="" VERIFY="" LAUNCH_PROOF="" FINALIZE="" STATUS_ID="" CANCEL_ID=""
SWEEP=0 DOCTOR=0 REQUIRE="" RECORD_SCRATCH="" RECORD_PID=""
REQUEST_MODE="" REQUEST_FILE="" REQUEST_STAGE="" REQUEST_SHA256=""
WORKER_HOME="$HOME/.codex-worker"
RELAY_MAX="${CODEX_RELAY_MAX:-8192}"
case "$RELAY_MAX" in ''|*[!0-9]*) RELAY_MAX=8192 ;; esac

manifest_lifecycle() {
  python3 - "$WORKER_HOME" "$@" 9>&- <<'PYEOF'
import contextlib
import datetime
import fcntl
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import sys
import tempfile
import time

worker = Path(sys.argv[1])
operation = sys.argv[2]
args = sys.argv[3:]
attempts = worker / "attempts"
terminal_states = {"succeeded", "failed", "orphaned", "cancelled"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def fail(message, code=2):
    print(f"CODEX_ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def attempt_name(scratch):
    path = Path(scratch)
    name = path.name
    if str(path.parent) != "/tmp" or not re.fullmatch(r"codex-worker\.[A-Za-z0-9_-]+", name):
        fail(f"invalid lifecycle scratch '{scratch}'")
    return name


def manifest_path_for(scratch):
    return attempts / f"{attempt_name(scratch)}.json"


def load_manifest(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        fail(f"cannot read attempt manifest {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"attempt manifest {path} is not a JSON object")
    return value


@contextlib.contextmanager
def manifest_lock(path, blocking=True):
    attempts.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        attempts.chmod(0o700)
    except OSError:
        pass
    with open(f"{path}.lock", "a+", encoding="utf-8") as lock:
        flags = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
        fcntl.flock(lock.fileno(), flags)
        yield


def fsync_dir(path):
    # A rename is only durable once the containing directory entry is synced
    # (power loss after os.replace can otherwise resurrect the old manifest).
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=f".{path.stem}.", suffix=".tmp", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_dir(path.parent)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def proc_start(pid):
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
        # The comm field is parenthesized and may contain spaces; fields after
        # its final ')' begin with field 3, making starttime (22) index 19.
        fields = raw[raw.rfind(")") + 2:].split()
        if fields[0] in {"Z", "X"}:
            return None
        return fields[19]
    except (OSError, IndexError, ValueError):
        return None


def is_live(manifest):
    try:
        pid = int(manifest["pid"])
    except (KeyError, TypeError, ValueError):
        return False
    expected = str(manifest.get("pid_start", ""))
    return pid > 1 and bool(expected) and proc_start(pid) == expected


def codex_live(manifest):
    # The codex child can outlive its run.sh leader (leader SIGKILLed: the
    # flock releases but codex keeps working). Its pid+start recorded by
    # record-codex is the identity that makes such a run still "live".
    try:
        pid = int(manifest["codex_pid"])
    except (KeyError, TypeError, ValueError):
        return False
    expected = str(manifest.get("codex_pid_start", ""))
    return pid > 1 and bool(expected) and proc_start(pid) == expected


def launch_grace(manifest):
    # A running manifest with no codex identity may be mid-stamp — the child
    # records itself (~100ms of bash+python startup) before exec'ing codex.
    # Treat it as live for a short grace so a racing sweep cannot orphan a
    # launching run and find-live still converges on it; a run whose stamp
    # FAILS never execs codex (run.sh gates exec on the stamp), so the grace
    # can only ever cover a launch, not mask a dead one for long.
    if manifest.get("codex_pid") is not None:
        return False
    started = manifest.get("started_at")
    if not isinstance(started, str):
        return False
    try:
        begun = datetime.datetime.fromisoformat(started)
    except ValueError:
        return False
    if begun.tzinfo is None:
        return False
    return (datetime.datetime.now(datetime.timezone.utc) - begun).total_seconds() < 2.0


def fingerprint(path):
    # Mirrors the shell output_fingerprint(): sha256 | ABSENT | SPECIAL | UNREADABLE.
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return "ABSENT"
    except OSError:
        return "UNREADABLE"
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        return "SPECIAL"
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    except OSError:
        return "UNREADABLE"


@contextlib.contextmanager
def output_destination_lock(destination):
    # Serializes fingerprint->write for one destination across concurrent runs
    # (two runs sharing an OUTPUT_FILE both passed the fingerprint check, both
    # renamed, last writer won and both reported success — Stage E P1).
    locks = worker / "output-locks"
    locks.mkdir(mode=0o700, parents=True, exist_ok=True)
    # fsencode, not encode: a valid Linux path may hold non-UTF-8 bytes that
    # arrive here surrogateescaped; encode() would crash finalization. The
    # bytes match what the legacy shell path hashes for the same destination.
    key = hashlib.sha256(os.fsencode(destination)).hexdigest()[:16]
    with open(locks / f"{key}.lock", "a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield


def _open_dir_nofollow(resolved):
    """Open an absolute, symlink-free directory as a fd, verifying no component
    is a symlink by walking from root with O_NOFOLLOW. Each fd is bound to its
    inode, so a same-UID swap of any component during the walk either was already
    passed (safe) or fails the next O_NOFOLLOW open. Raises OSError on any
    symlinked/missing component. Caller closes the returned fd."""
    parts = Path(resolved).parts
    fd = os.open(parts[0], os.O_DIRECTORY | os.O_CLOEXEC)   # root ('/') is trusted
    try:
        for comp in parts[1:]:
            nxt = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def deliver_output(manifest, scratch):
    """Deliver last.txt to the requested OUTPUT_FILE. Returns (outcome, error, sha):
    outcome in {None, "delivered", "preserved-worker-file", "failed"}; sha is the
    delivered payload's sha256 (the manifest's binding record — the destination
    is caller-owned after delivery, so later reads may legitimately differ)."""
    destination = manifest.get("output_file")
    if not destination:
        return None, None, None
    if manifest.get("exit_code") != 0:
        return None, None, None
    baseline = str(manifest.get("output_baseline", "") or "")
    source = Path(scratch) / "last.txt"
    try:
        payload = source.read_bytes()
    except OSError as exc:
        return "failed", f"cannot read final message for OUTPUT_FILE delivery: {exc}", None
    payload_sha = hashlib.sha256(payload).hexdigest()
    with output_destination_lock(destination):
        current = fingerprint(destination)
        if current == payload_sha:
            return "delivered", None, payload_sha      # idempotent re-delivery
        if current in ("SPECIAL", "UNREADABLE"):
            return "failed", f"requested OUTPUT_FILE '{destination}' is not a writable regular file", None
        changed = current != baseline if baseline else current != "ABSENT"
        if changed:
            # The worker (or a concurrent run) wrote the destination during the
            # run — preserve that file; the final message lives in the archive.
            if manifest.get("archive"):
                return "preserved-worker-file", None, None
            return "failed", (
                f"OUTPUT_FILE '{destination}' changed during the run and no archive "
                f"exists to hold the final message; content is at {source}"
            ), None
        dest = Path(destination)
        # The leaf fingerprint above refuses a symlink destination, but the
        # unsandboxed runner would still follow a SYMLINKED ANCESTOR the
        # sandboxed worker planted during the run, redirecting the write
        # outside the workspace (mirror-gate review 2026-07-14, high). The
        # destination path must resolve to itself, component by component.
        resolved_parent = Path(os.path.realpath(dest.parent))
        if resolved_parent != Path(os.path.normpath(dest.parent)):
            return "failed", (
                f"OUTPUT_FILE '{destination}' parent resolves through a symlink "
                f"(to '{resolved_parent}'); pass the fully-resolved path"
            ), None
        # A realpath check followed by PATH-based mkstemp+os.replace leaves a
        # symlink-swap race: a concurrent same-UID sandboxed worker can swap an
        # ancestor for a symlink AFTER the check and redirect the unsandboxed
        # finalizer outside the workspace (mirror-gate round 5, high). Eliminate
        # the path re-resolution entirely: walk the parent chain from root with
        # O_NOFOLLOW (any symlinked component fails the open), then create the
        # temp and rename VIA THE DIRECTORY FD — both bound to the real inode, so
        # no post-check swap of any path component can redirect them.
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            return "failed", f"cannot create OUTPUT_FILE parent '{dest.parent}': {exc}", None
        try:
            pfd = _open_dir_nofollow(resolved_parent)
        except OSError as exc:
            return "failed", (
                f"OUTPUT_FILE '{destination}' parent is not a symlink-free real "
                f"directory ({exc}); refusing to deliver"
            ), None
        try:
            leaf = dest.name
            temporary = f".codex-output.{os.getpid()}.{os.urandom(8).hex()}"
            fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_CLOEXEC,
                         0o600, dir_fd=pfd)
            try:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, leaf, src_dir_fd=pfd, dst_dir_fd=pfd)
                os.fsync(pfd)
            except BaseException:
                try:
                    os.unlink(temporary, dir_fd=pfd)
                except OSError:
                    pass
                raise
        except OSError as exc:
            return "failed", f"cannot write OUTPUT_FILE '{destination}': {exc}", None
        finally:
            os.close(pfd)
        return "delivered", None, payload_sha


def empty_usage():
    return {"input": 0, "cached": 0, "output": 0, "reasoning": 0}


def add_usage(total, usage):
    mapping = {
        "input": "input_tokens",
        "cached": "cached_input_tokens",
        "output": "output_tokens",
        "reasoning": "reasoning_output_tokens",
    }
    found = False
    for target, source in mapping.items():
        value = usage.get(source)
        if isinstance(value, int):
            total[target] += value
            found = True
    return found


def json_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    value = json.loads(line)
                except (TypeError, ValueError):
                    # usage_parts preserves the historical grep payload, which
                    # begins at the "type" key instead of the opening brace.
                    try:
                        value = json.loads("{" + line) if line.lstrip().startswith('"') else None
                    except (TypeError, ValueError):
                        continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def scan_usage(scratch):
    scratch = Path(scratch)
    session = None
    usage = empty_usage()
    usage_found = False
    telemetry = scratch / "telemetry"
    if telemetry.is_file():
        try:
            lines = telemetry.read_text(errors="replace").splitlines()
        except OSError:
            lines = []
        if lines and lines[0]:
            session = lines[0]
        if len(lines) > 1:
            match = re.fullmatch(
                r"input=(\d+) cached=(\d+) output=(\d+) reasoning=(\d+)", lines[1]
            )
            if match:
                usage = dict(zip(usage, map(int, match.groups())))
                usage_found = True

    events = list(json_lines(scratch / "events.jsonl"))
    for event in events:
        candidate = event.get("thread_id") or event.get("session_id")
        if isinstance(candidate, str) and candidate:
            session = session or candidate

    parts = scratch / "usage_parts"
    usage_events = list(json_lines(parts)) if parts.is_file() else events
    if not usage_found:
        for event in usage_events:
            if event.get("type") == "turn.completed" and isinstance(event.get("usage"), dict):
                usage_found = add_usage(usage, event["usage"]) or usage_found

    # Review runs use an isolated rollout tree. A normal orphan may have its
    # session rollout in the worker home; only inspect that shared tree when a
    # session id is already known so another run cannot be imported by mistake.
    rollout_files = glob.glob(str(scratch / "home/sessions/*/*/*/rollout-*.jsonl"))
    if session:
        rollout_files.extend(
            path for path in glob.glob(str(worker / "sessions/*/*/*/rollout-*.jsonl"))
            if session in path
        )
    rollout_totals = empty_usage()
    rollout_found = False
    for rollout in sorted(set(rollout_files)):
        file_usage = None
        for event in json_lines(rollout):
            payload = event.get("payload")
            if not isinstance(payload, dict):
                continue
            candidate = payload.get("session_id") or payload.get("thread_id")
            if isinstance(candidate, str) and candidate:
                session = session or candidate
            if payload.get("type") == "session_meta":
                candidate = payload.get("id")
                if isinstance(candidate, str) and candidate:
                    session = session or candidate
            if payload.get("type") == "token_count":
                candidate_usage = (payload.get("info") or {}).get("total_token_usage")
                if isinstance(candidate_usage, dict):
                    file_usage = candidate_usage
        if file_usage:
            rollout_found = add_usage(rollout_totals, file_usage) or rollout_found
    if not usage_found and rollout_found:
        usage, usage_found = rollout_totals, True

    if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9-]+", session):
        session = "missing"
    return session or "missing", usage, usage_found


def read_exit(scratch, default=1):
    try:
        return int((Path(scratch) / "exit").read_text().strip())
    except (OSError, ValueError):
        return default


def archive_result(scratch, session):
    source = Path(scratch) / "last.txt"
    if session == "missing" or not source.is_file():
        return None, None
    results = worker / "results"
    results.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination = results / f"{session}.txt"
    fd, temporary = tempfile.mkstemp(prefix=f".{session}.", suffix=".tmp", dir=results)
    try:
        with os.fdopen(fd, "wb") as target, open(source, "rb") as origin:
            shutil.copyfileobj(origin, target)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, destination)
        fsync_dir(results)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        return None, None
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    return str(destination), digest


def files_written_count(scratch, manifest):
    scratch = Path(scratch)
    if not (scratch / "FOOTER").is_file() or manifest.get("sandbox") != "workspace-write":
        return None
    try:
        boundary = (scratch / "marker").stat().st_mtime_ns
    except OSError:
        return 0
    count = 0
    try:
        for root, directories, files in os.walk(manifest.get("cwd", "")):
            directories[:] = [name for name in directories if name not in {".git", "node_modules"}]
            for name in files:
                try:
                    info = os.stat(Path(root) / name, follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISREG(info.st_mode) and info.st_mtime_ns > boundary:
                    count += 1
                    if count == 200:
                        return count
    except OSError:
        pass
    return count


def append_usage(manifest, scratch):
    usage = manifest["usage"]
    status = "ok" if manifest["state"] == "succeeded" else "error"
    line = (
        f"{manifest['ended_at']} {status} session={manifest['session']} "
        f"input={usage['input']} cached={usage['cached']} "
        f"output={usage['output']} reasoning={usage['reasoning']}"
    )
    files = files_written_count(scratch, manifest)
    if files is not None:
        line += f" files={files}"
    line += f" cwd={manifest.get('cwd', '')}"
    if manifest.get("archive"):
        line += f" file={manifest['archive']}"
    # Returns True once the line is durably in usage.log — including when a
    # finalize crashed between a prior append and its usage_logged checkpoint
    # (a real session id appears at most once, so the retry skips instead of
    # duplicating). fsync before the checkpoint write closes the reverse
    # ordering: a flag that outlives an unsynced append (re-review 2026-07-14).
    log_path = worker / "usage.log"
    session = manifest.get("session")
    try:
        worker.mkdir(mode=0o700, parents=True, exist_ok=True)
        if session and session != "missing":
            try:
                if f"session={session}" in log_path.read_text(encoding="utf-8", errors="replace"):
                    return True
            except FileNotFoundError:
                pass
        with open(log_path, "a", encoding="utf-8") as stream:
            stream.write(line + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        # First-ever creation: the directory entry must be durable too, or a
        # power loss could keep the fsynced usage_logged checkpoint while
        # losing the log file itself (re-review round 2).
        fsync_dir(worker)
        return True
    except OSError:
        return False


if operation == "init":
    if len(args) != 11:
        fail("internal manifest init argument mismatch")
    (scratch, task_hash, cwd, sandbox, model, effort, pid, pid_start,
     output_file, output_baseline, request_sha) = args
    path = manifest_path_for(scratch)
    try:
        pid_value = int(pid)
        pid_start_value = int(pid_start)
    except ValueError:
        fail("cannot record attempt without a numeric pid and pid_start", 3)
    value = {
        "attempt_id": attempt_name(scratch),
        "state": "running",
        "task_hash": task_hash,
        "cwd": cwd,
        "sandbox": sandbox,
        "model": model,
        "effort": effort,
        "pid": pid_value,
        "pid_start": pid_start_value,
        "started_at": now(),
    }
    if output_file:
        value["output_file"] = output_file
        value["output_baseline"] = output_baseline
    if request_sha:
        value["request_sha256"] = request_sha
    with manifest_lock(path):
        if path.exists():
            fail(f"attempt manifest already exists for {value['attempt_id']}", 3)
        atomic_json(path, value)
    raise SystemExit(0)


if operation == "finalize":
    if len(args) != 1:
        fail("--finalize takes one scratch path")
    scratch = args[0]
    path = manifest_path_for(scratch)
    if not path.is_file() or path.is_symlink():
        fail(f"no attempt manifest for {attempt_name(scratch)}", 3)
    with manifest_lock(path):
        manifest = load_manifest(path)
        if manifest.get("state") in terminal_states:
            raise SystemExit(0)
        if manifest.get("state") != "running":
            fail(f"attempt {manifest.get('attempt_id', path.stem)} has invalid state", 3)
        # Refuse to terminalize a LIVE run: an early or errant --finalize
        # before run.sh writes the exit file would otherwise publish an
        # immutable false `failed` while codex is still working. run.sh
        # always writes exit before its own finalize; the poll path only
        # finalizes after `alive` says nothing is left (re-review 2026-07-14).
        if not (Path(scratch) / "exit").is_file() and (
                is_live(manifest) or codex_live(manifest) or launch_grace(manifest)):
            fail(f"attempt {manifest.get('attempt_id', path.stem)} is still running; refusing to finalize", 3)
        session, usage, _ = scan_usage(scratch)
        exit_code = read_exit(scratch)
        archive, archive_sha = archive_result(scratch, session)
        manifest.update({
            "session": session,
            "exit_code": exit_code,
            "usage": usage,
            "archive": archive,
            "archive_sha256": archive_sha,
            "ended_at": now(),
        })
        if archive is None and session != "missing" and (Path(scratch) / "last.txt").is_file():
            # Archive is best-effort by design; record the gap so a null
            # archive on a succeeded attempt is diagnosable, not silent.
            manifest["archive_error"] = "archive copy failed; final message remains in the scratch"
        # Delivery happens HERE, not on the poll path, so a launch that is
        # never polled still exports, and the terminal state tells the truth
        # about whether the requested artifact actually landed (Stage E).
        delivery, delivery_error, delivered_sha = deliver_output(manifest, scratch)
        state = "succeeded" if exit_code == 0 else "failed"
        if delivery == "failed":
            state = "failed"
        manifest["state"] = state
        if delivery:
            manifest["output_delivery"] = delivery
        if delivered_sha:
            manifest["output_sha256"] = delivered_sha
        if delivery_error:
            manifest["error"] = delivery_error
        # Publish LAST: the terminal manifest is immutable, so everything it
        # promises (usage line, archive, delivery) must already exist when a
        # reader sees it. usage_logged makes the append idempotent across a
        # crashed-and-retried finalization. An unwritable usage.log must not
        # convert a real outcome into a failure (v3.9 parity) — publish the
        # true state and record the proof gap honestly.
        if not manifest.get("usage_logged"):
            if append_usage(manifest, scratch):
                intermediate = dict(manifest)
                intermediate["state"] = "running"
                intermediate["usage_logged"] = True
                atomic_json(path, intermediate)
                manifest["usage_logged"] = True
            else:
                manifest["usage_log_error"] = (
                    "cannot append usage.log; --verify will not corroborate this session"
                )
        atomic_json(path, manifest)
    raise SystemExit(0)


if operation == "read":
    if len(args) != 1:
        fail("internal manifest read argument mismatch")
    path = manifest_path_for(args[0])
    if not path.is_file() or path.is_symlink():
        raise SystemExit(5)
    manifest = load_manifest(path)
    if manifest.get("state") not in terminal_states:
        raise SystemExit(4)
    usage = manifest.get("usage") or empty_usage()
    if not isinstance(usage, dict):
        usage = empty_usage()      # hand-corrupted manifest must not crash read
    print(manifest.get("state", "failed"))
    print(manifest.get("session", "missing"))
    print(
        f"input={usage.get('input', 0)} cached={usage.get('cached', 0)} "
        f"output={usage.get('output', 0)} reasoning={usage.get('reasoning', 0)}"
    )
    print(manifest.get("archive") or "-")
    print(manifest.get("output_delivery") or "-")
    print(manifest.get("output_file") or "-")
    print(manifest.get("error") or "-")
    raise SystemExit(0)


if operation == "status":
    valid_status_id = len(args) == 1 and (
        re.fullmatch(r"codex-worker\.[A-Za-z0-9_-]+", args[0])
        or re.fullmatch(r"[A-Za-z0-9-]+", args[0])
    )
    if not valid_status_id:
        fail("--status takes an attempt id or session id")
    identifier = args[0]
    direct = attempts / f"{identifier}.json"
    candidates = []
    if direct.is_file() and not direct.is_symlink():
        candidates.append((direct, load_manifest(direct)))
    elif attempts.is_dir():
        for path in sorted(attempts.glob("*.json")):
            if path.is_symlink():
                continue
            try:
                manifest = load_manifest(path)
            except SystemExit:
                continue
            if manifest.get("session") == identifier:
                candidates.append((path, manifest))
    if not candidates:
        fail(f"no attempt manifest found for {identifier}")
    path, _ = max(
        candidates,
        key=lambda item: (item[1].get("ended_at") or item[1].get("started_at") or "", str(item[0])),
    )
    sys.stdout.write(path.read_text())
    raise SystemExit(0)


if operation == "sweep":
    # Optional scratch arg sweeps just that attempt — the poll path uses it to
    # reconcile a run whose leader AND codex both died (nothing left to
    # finalize it), so attach/poll loops terminate instead of running forever.
    if len(args) > 1:
        fail("--sweep takes at most one scratch path")
    single = bool(args)
    if args:
        targets = [manifest_path_for(args[0])]
    else:
        targets = sorted(attempts.glob("*.json")) if attempts.is_dir() else []
    checked = live = orphaned = errors = 0
    for path in targets:
        if path.is_symlink():
            errors += 1
            continue
        if not path.is_file():
            continue
        try:
            # Single-target sweeps run inline on the POLL path — never block
            # on a manifest lock a live finalizer holds; contention IS proof
            # the attempt is being finalized, i.e. live (re-review round 2).
            with manifest_lock(path, blocking=not single):
                manifest = load_manifest(path)
                if manifest.get("state") != "running":
                    continue
                checked += 1
                if is_live(manifest) or codex_live(manifest) or launch_grace(manifest):
                    live += 1
                    continue
                scratch = f"/tmp/{manifest.get('attempt_id', path.stem)}"
                session, usage, _ = scan_usage(scratch)
                manifest.update({
                    "state": "orphaned",
                    "session": session,
                    "usage": usage,
                    "ended_at": now(),
                })
                exit_path = Path(scratch) / "exit"
                if exit_path.is_file():
                    manifest["exit_code"] = read_exit(scratch)
                # An orphan is this attempt's LAST writer — append its proof
                # line here or the session never reaches usage.log and a later
                # --verify would wrongly call it forged (re-review 2026-07-14).
                if session != "missing" and not manifest.get("usage_logged"):
                    if append_usage(manifest, scratch):
                        manifest["usage_logged"] = True
                    else:
                        manifest["usage_log_error"] = (
                            "cannot append usage.log; --verify will not corroborate this session"
                        )
                atomic_json(path, manifest)
                orphaned += 1
        except BlockingIOError:
            live += 1
        except (OSError, SystemExit, ValueError):
            errors += 1
    print(f"sweep: checked={checked} live={live} orphaned={orphaned} errors={errors}")
    raise SystemExit(0)


if operation == "cancel":
    if len(args) != 1 or not re.fullmatch(r"codex-worker\.[A-Za-z0-9_-]+", args[0]):
        fail("--cancel takes an attempt id")
    identifier = args[0]
    path = attempts / f"{identifier}.json"
    if not path.is_file() or path.is_symlink():
        fail(f"no attempt manifest found for {identifier}")
    # Signal BEFORE taking the manifest lock: a finalizer hung with the lock
    # held is itself a cancellation target, and blocking on its lock would
    # wedge --cancel behind the very process it is asked to stop (Stage E).
    manifest = load_manifest(path)
    if manifest.get("state") in terminal_states:
        fail(f"attempt {identifier} is already {manifest.get('state')}", 3)
    if manifest.get("state") != "running":
        fail(f"attempt {identifier} has invalid state; refusing to signal", 3)
    try:
        lead_pid = int(manifest.get("pid") or 0)
    except (TypeError, ValueError):
        fail(f"attempt {identifier} manifest is corrupt (non-numeric pid); refusing to signal", 3)

    def verified_member():
        # A pid is only signalable while its recorded start-time still
        # matches — re-checked immediately before EVERY signal, closing the
        # pid-reuse window the old getpgid-only path left open (Stage E).
        if is_live(manifest):
            return int(manifest["pid"])
        if codex_live(manifest):
            return int(manifest["codex_pid"])
        return None

    def signal_group(sig):
        member = verified_member()
        if member is None:
            return False
        try:
            pgid = os.getpgid(member)
        except (ProcessLookupError, PermissionError):
            return False
        if pgid != lead_pid:
            return False       # member left our group; nothing verifiable to signal
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        return True

    if verified_member() is None:
        fail(f"attempt {identifier} pid identity does not match; refusing to signal", 3)
    termed = signal_group(signal.SIGTERM)
    deadline = time.monotonic() + 2.0
    while verified_member() is not None and time.monotonic() < deadline:
        time.sleep(0.05)
    # Escalate to group KILL UNCONDITIONALLY once a verified group was TERMed
    # (HANDOFF #2): a TERM-ignoring descendant must not outlive "cancelled",
    # even when every RECORDED identity died during the wait. With a live
    # verified member, signal_group re-checks identity as usual; with none,
    # the pgid verified <=2s ago is the only remaining handle — the reuse
    # window (entire group dead AND the same pgid reallocated to a stranger
    # within seconds) is accepted as negligible against leaving a survivor.
    if termed:
        if not signal_group(signal.SIGKILL):
            try:
                os.killpg(lead_pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        deadline = time.monotonic() + 1.0
        while verified_member() is not None and time.monotonic() < deadline:
            time.sleep(0.05)
    with manifest_lock(path):
        manifest = load_manifest(path)
        if manifest.get("state") in terminal_states:
            # The finalizer beat us to a terminal state after our signals.
            print(f"attempt {identifier} finalized as {manifest.get('state')} during cancel")
            raise SystemExit(0)
        session, usage, _ = scan_usage(f"/tmp/{identifier}")
        manifest.update({
            "state": "cancelled",
            "session": session,
            "usage": usage,
            "ended_at": now(),
        })
        atomic_json(path, manifest)
        proof = worker / "launches" / identifier
        try:
            if proof.read_text().strip() == f"/tmp/{identifier}":
                proof.unlink()
        except OSError:
            pass
    print(f"cancelled {identifier}")
    raise SystemExit(0)


if operation == "record-codex":
    # run.sh records its codex child's identity per attempt so a launch whose
    # lock died with its holder can still be recognized as live (find-live)
    # and so cancel/sweep can see past a dead leader (Stage E).
    if len(args) != 2:
        fail("internal record-codex argument mismatch")
    scratch, pid = args
    path = manifest_path_for(scratch)
    # Nonzero exits matter here: run.sh gates `exec codex` on this stamp, so
    # a run that cannot durably record its identity never starts codex (and a
    # cancelled/terminalized manifest can never gain a fresh codex process).
    if not path.is_file() or path.is_symlink():
        raise SystemExit(4)
    try:
        pid_value = int(pid)
    except ValueError:
        fail("internal record-codex pid must be numeric")
    start = proc_start(pid_value)
    if start is None:
        raise SystemExit(4)      # caller pid vanished — nothing durable to record
    with manifest_lock(path):
        manifest = load_manifest(path)
        if manifest.get("state") != "running":
            raise SystemExit(4)  # cancelled/finalized mid-launch — refuse the start
        manifest["codex_pid"] = pid_value
        manifest["codex_pid_start"] = start
        atomic_json(path, manifest)
    raise SystemExit(0)


if operation == "find-live":
    # Rollout/lock-death convergence: is a run with this task_hash still alive
    # (leader or codex child)? Prints its scratch path; exit 4 when none.
    if len(args) != 1 or not re.fullmatch(r"[0-9a-f]{16}", args[0]):
        fail("internal find-live argument mismatch")
    task_hash = args[0]
    if attempts.is_dir():
        for path in sorted(attempts.glob("*.json")):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                manifest = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if not isinstance(manifest, dict):
                continue
            if manifest.get("state") != "running" or manifest.get("task_hash") != task_hash:
                continue
            if is_live(manifest) or codex_live(manifest) or launch_grace(manifest):
                scratch = f"/tmp/{manifest.get('attempt_id', path.stem)}"
                if os.path.isdir(scratch):
                    print(scratch)
                    raise SystemExit(0)
    raise SystemExit(4)


if operation == "alive":
    # Will anything still finalize this attempt? 0 = leader or codex live.
    if len(args) != 1:
        fail("internal alive argument mismatch")
    path = manifest_path_for(args[0])
    if not path.is_file() or path.is_symlink():
        raise SystemExit(1)
    manifest = load_manifest(path)
    if manifest.get("state") != "running":
        raise SystemExit(1)
    raise SystemExit(0 if (is_live(manifest) or codex_live(manifest) or launch_grace(manifest)) else 1)


fail(f"unknown internal lifecycle operation {operation}")
PYEOF
}

doctor_probe() {
  python3 - "$WORKER_HOME" "$REQUIRE" 9>&- <<'PYEOF'
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

worker = Path(sys.argv[1])
required = sys.argv[2]
path_value = shutil.which("codex")
if not path_value:
    print("CODEX_ERROR: codex binary not found", file=sys.stderr)
    raise SystemExit(3)
binary = Path(os.path.realpath(path_value))
try:
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
except OSError as exc:
    print(f"CODEX_ERROR: cannot hash codex binary {binary}: {exc}", file=sys.stderr)
    raise SystemExit(3)

worker.mkdir(mode=0o700, parents=True, exist_ok=True)
cache = worker / "doctor.json"
lock_path = worker / "doctor.json.lock"


def run_probe(arguments):
    try:
        result = subprocess.run(
            [str(binary), *arguments], text=True, capture_output=True,
            timeout=3, stdin=subprocess.DEVNULL, close_fds=True,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout + result.stderr


with open(lock_path, "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    report = None
    try:
        candidate = json.loads(cache.read_text())
        if candidate.get("sha256") == digest:
            report = candidate
    except (OSError, ValueError, AttributeError):
        pass

    if report is None:
        version_text = run_probe(["--version"]).strip().splitlines()
        version = version_text[0] if version_text else "unknown"
        exec_help = run_probe(["exec", "--help"])
        review_help = run_probe(["review", "--help"])
        features = run_probe(["features", "list"])
        combined = "\n".join((exec_help, features)).lower()
        known_efforts = ["none", "low", "medium", "high", "xhigh", "max", "ultra"]
        detected = [name for name in known_efforts if re.search(rf"(?<![a-z]){name}(?![a-z])", combined)]
        efforts = detected if len(detected) >= 2 else known_efforts
        # ultra is rejected at launch (multi-agent profile disabled) — never
        # advertise it as a runner capability even when the binary supports it.
        efforts = [name for name in efforts if name != "ultra"]
        review_modes = []
        review_lower = review_help.lower()
        for mode, marker in (
            ("uncommitted", "--uncommitted"),
            ("base", "--base"),
            ("commit", "--commit"),
        ):
            if marker in review_lower:
                review_modes.append(mode)
        if review_help and ("prompt" in review_lower or "stdin" in review_lower or "custom" in review_lower):
            review_modes.append("custom")
        multi_agent = bool(re.search(r"\bmulti[_-]agent\b", "\n".join((exec_help, features)).lower()))
        capabilities = [f"effort:{value}" for value in efforts]
        capabilities.extend(f"review:{value}" for value in review_modes)
        if multi_agent:
            capabilities.append("multi_agent")
        report = {
            "path": str(binary),
            "version": version,
            "sha256": digest,
            "effort": efforts,
            "effort_source": "help" if len(detected) >= 2 else "runner-static",
            "review_modes": review_modes,
            "multi_agent": multi_agent,
            "capabilities": capabilities,
            "probed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        }
        fd, temporary = tempfile.mkstemp(prefix=".doctor.", suffix=".tmp", dir=worker)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(report, stream, sort_keys=True, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, cache)
        except BaseException:
            try:
                os.close(fd)
            except OSError:
                pass
            try:
                os.unlink(temporary)
            except OSError:
                pass
            raise

print(json.dumps(report, sort_keys=True, indent=2))
if required and required not in report.get("capabilities", []):
    print(f"CODEX_ERROR: required capability '{required}' is absent", file=sys.stderr)
    raise SystemExit(1)
PYEOF
}

parse_request_envelope() { # $1=stdin|file $2=file-path-or-empty
  local mode=$1 source=$2 raw rc
  REQUEST_STAGE=$(mktemp -d /tmp/codex-request.XXXXXX) \
    || { echo "CODEX_ERROR: cannot create request scratch" >&2; return 2; }
  raw="$REQUEST_STAGE/request.raw"
  if [ "$mode" = file ]; then
    case "$source" in
      /*) : ;;
      *) echo "CODEX_ERROR: --request-file must be an absolute path, got '$source'" >&2; return 2 ;;
    esac
    # A device/FIFO/symlink would block or exhaust storage before the grammar
    # ever runs; requests are runner-staged regular files, and 5MB dwarfs any
    # legitimate envelope (prompts must not embed >4KB of data anyway).
    [ -f "$source" ] && [ ! -L "$source" ] \
      || { echo "CODEX_ERROR: --request-file must be an existing regular file (no symlink/device/FIFO): $source" >&2; return 2; }
    # The leaf check above misses SYMLINKED ANCESTORS: a linked directory
    # component re-points the read at a file the caller never named (e.g. a
    # credential) which is then transmitted to codex as task text
    # (mirror-gate review 2026-07-14). Require a self-resolving path.
    [ "$(realpath -m -- "$source" 2>/dev/null)" = "$source" ] \
      || { echo "CODEX_ERROR: --request-file path resolves through a symlink; pass the fully-resolved path: $source" >&2; return 2; }
    # The shell checks above are advisory fast-fails: they validate a PATHNAME,
    # and a writable-directory attacker can swap the file (or plant a symlink)
    # between that check and a by-name read, turning the copy into an
    # arbitrary-file disclosure transmitted to codex as task text (mirror-gate
    # review 2026-07-14, high — the old `head -- "$source"` reopened by name).
    # Authoritative read: the same O_NOFOLLOW parent-chain walk as OUTPUT_FILE
    # delivery — every directory component fd-bound, leaf opened O_NOFOLLOW
    # (O_NONBLOCK so a swapped-in FIFO cannot hang the launch), validation and
    # the bounded read both against the one fstat'd fd.
    python3 - "$source" "$raw" <<'PYEOF' || return 2
import os
import stat as stat_mod
import sys

source, raw = sys.argv[1:]
LIMIT = 5242880


def fail(detail):
    sys.stderr.write("CODEX_ERROR: " + detail + "\n")
    raise SystemExit(2)


parts = source.split("/")[1:]
fd = os.open("/", os.O_DIRECTORY | os.O_CLOEXEC)
leaf = None
try:
    try:
        for comp in parts[:-1]:
            nxt = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = nxt
        leaf = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                       dir_fd=fd)
    except OSError as exc:
        fail(f"--request-file path resolves through a symlink or is unreadable: {source}: {exc.strerror}")
finally:
    os.close(fd)
try:
    st = os.fstat(leaf)
    if not stat_mod.S_ISREG(st.st_mode):
        fail(f"--request-file must be an existing regular file (no symlink/device/FIFO): {source}")
    if st.st_size > LIMIT:
        fail(f"--request-file larger than 5MB: {source}")
    chunks, total = [], 0
    while total <= LIMIT:
        chunk = os.read(leaf, 1048576)
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
finally:
    os.close(leaf)
if total > LIMIT:
    fail(f"--request-file larger than 5MB: {source}")
with open(raw, "wb") as out:
    out.write(b"".join(chunks))
PYEOF
  else
    cat > "$raw" \
      || { echo "CODEX_ERROR: cannot read request from stdin" >&2; return 2; }
  fi
  REQUEST_SHA256=$(sha256sum "$raw" | cut -d' ' -f1)

  # CRLF is normalized to LF as one whole-request policy. The hash above is of
  # the original bytes; LF requests retain task bytes exactly after boundary.
  python3 - "$raw" "$REQUEST_STAGE" "$INVOCATION_PWD" <<'PYEOF'
import os
import re
import sys

raw_path, stage, invocation_pwd = sys.argv[1:]
data = open(raw_path, "rb").read().replace(b"\r\n", b"\n")
lines = data.splitlines(keepends=True)


def fail(kind, detail):
    # Contract: CODEX_ERROR rides stderr with exit 2, same as every other
    # validation error (re-review 2026-07-14 — this wrote to stdout).
    sys.stderr.buffer.write(b"CODEX_ERROR: " + kind + b" " + detail + b"\n")
    raise SystemExit(2)


if b"\x00" in data:
    # Bash command substitution silently strips NUL, so a NUL-bearing SCHEMA
    # (or task) would launch with different bytes than the request carried.
    fail(b"request contains a NUL byte", b"(binary payloads cannot ride the request envelope)")
known = {
    b"EFFORT", b"SANDBOX", b"CWD", b"NETWORK", b"MCP", b"MODEL",
    b"RESUME", b"LONG", b"SCHEMA", b"REVIEW", b"OUTPUT_FILE",
    b"CREATE_CWD",
}
seen = set()
values = {}
task = b""

for index, physical in enumerate(lines):
    line = physical[:-1] if physical.endswith(b"\n") else physical
    if line == b"":
        task = b"".join(lines[index + 1:])
        break
    match = re.match(br"^([A-Z_]+): ", line)
    if not match:
        task = b"".join(lines[index:])
        break
    name = match.group(1)
    if name not in known:
        fail(b"unknown directive", line)
    if name in seen:
        fail(b"duplicate directive", name)
    seen.add(name)
    values[name] = line[len(name) + 2:]
else:
    task = b""

unsafe = re.compile(br"['\"`$\\\r\n]")
efforts = {b"none", b"low", b"medium", b"high", b"xhigh", b"max", b"ultra"}
uuid = re.compile(br"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
mcp = re.compile(br"^[A-Za-z0-9_-]+(?:,[A-Za-z0-9_-]+)*$")
review = re.compile(br"^(?:uncommitted|custom|base=[A-Za-z0-9._/-]+|commit=[0-9A-Fa-f]+)$")

for name, value in values.items():
    source_line = name + b": " + value
    valid = True
    if name == b"EFFORT":
        valid = value in efforts
    elif name == b"SANDBOX":
        valid = value in {b"read-only", b"workspace-write"}
    elif name == b"CWD":
        valid = value == b"self" or (
            value.startswith(b"/")
            and value not in {b"", b"undefined", b"null", b"NaN"}
            and not any(part in {b"undefined", b"null", b"NaN"} for part in value.split(b"/"))
        )
    elif name in {b"NETWORK", b"LONG", b"CREATE_CWD"}:
        valid = value == b"on"
    elif name == b"MCP":
        valid = bool(mcp.fullmatch(value))
    elif name == b"RESUME":
        valid = bool(uuid.fullmatch(value))
    elif name == b"REVIEW":
        valid = bool(review.fullmatch(value))
    elif name == b"OUTPUT_FILE":
        valid = (
            value.startswith(b"/")
            and not re.search(br"\s", value)
            and not any(part in {b"undefined", b"null", b"NaN"} for part in value.split(b"/"))
        )
    if name in {b"CWD", b"MODEL", b"RESUME", b"MCP", b"EFFORT", b"SANDBOX", b"REVIEW", b"OUTPUT_FILE"}:
        valid = valid and not unsafe.search(value)
    if not valid:
        fail(b"invalid directive value", source_line)

if values.get(b"CWD") == b"self":
    values[b"CWD"] = os.fsencode(invocation_pwd)
for name, value in values.items():
    open(os.path.join(stage, os.fsdecode(name)), "wb").write(value)
open(os.path.join(stage, "task.txt"), "wb").write(task)
PYEOF
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  if [ -f "$REQUEST_STAGE/EFFORT" ]; then IFS= read -r EFFORT < "$REQUEST_STAGE/EFFORT" || true; fi
  if [ -f "$REQUEST_STAGE/SANDBOX" ]; then IFS= read -r SANDBOX < "$REQUEST_STAGE/SANDBOX" || true; fi
  if [ -f "$REQUEST_STAGE/CWD" ]; then IFS= read -r CWD < "$REQUEST_STAGE/CWD" || true; fi
  if [ -f "$REQUEST_STAGE/NETWORK" ]; then NETWORK=1; fi
  if [ -f "$REQUEST_STAGE/MCP" ]; then IFS= read -r MCP < "$REQUEST_STAGE/MCP" || true; fi
  if [ -f "$REQUEST_STAGE/MODEL" ]; then IFS= read -r MODEL < "$REQUEST_STAGE/MODEL" || true; fi
  if [ -f "$REQUEST_STAGE/RESUME" ]; then IFS= read -r RESUME < "$REQUEST_STAGE/RESUME" || true; fi
  if [ -f "$REQUEST_STAGE/SCHEMA" ]; then SCHEMA_FILE="$REQUEST_STAGE/SCHEMA"; fi
  if [ -f "$REQUEST_STAGE/REVIEW" ]; then IFS= read -r REVIEW < "$REQUEST_STAGE/REVIEW" || true; fi
  if [ -f "$REQUEST_STAGE/OUTPUT_FILE" ]; then IFS= read -r OUTPUT_FILE < "$REQUEST_STAGE/OUTPUT_FILE" || true; fi
  if [ -f "$REQUEST_STAGE/CREATE_CWD" ]; then CREATE_CWD=1; fi
  # LONG is deliberately parsed, validated, and then IGNORED: it is advisory
  # only. The runner detaches every task regardless, so there is nothing to
  # switch on — it just tells the caller to expect CODEX_RUNNING continuations.
  # Accepting it keeps `LONG: on` from tripping the unknown-directive error.
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup_request_stage() {
  [ -z "$REQUEST_STAGE" ] || rm -rf "$REQUEST_STAGE"
}
trap cleanup_request_stage EXIT

while [ $# -gt 0 ]; do
  # A flag invoked without its operand must be a contracted invalid request
  # (CODEX_ERROR + exit 2), never a raw `set -u` unbound-variable crash.
  case "$1" in
    --model|--effort|--sandbox|--cwd|--mcp|--schema|--schema-file|--resume|--review|--output-file|--request-file|--poll|--recover|--verify|--finalize|--status|--cancel|--require|--poll-budget|--extract-review)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || { echo "CODEX_ERROR: $1 requires an operand" >&2; exit 2; } ;;
    --record-codex)
      { [ $# -ge 3 ] && [ -n "$2" ] && [ -n "$3" ]; } || { echo "CODEX_ERROR: --record-codex requires a scratch path and a pid" >&2; exit 2; } ;;
  esac
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --effort) EFFORT=$2; shift 2 ;;
    --sandbox) SANDBOX=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --mcp) MCP=$2; shift 2 ;;
    --schema) SCHEMA=$2; shift 2 ;;
    --schema-file) SCHEMA_FILE=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --review) REVIEW=$2; shift 2 ;;
    --output-file) OUTPUT_FILE=$2; shift 2 ;;
    --create-cwd) CREATE_CWD=1; shift ;;
    --parse-request)
      [ -z "$REQUEST_MODE" ] || { echo "CODEX_ERROR: request mode specified more than once"; exit 2; }
      REQUEST_MODE="stdin"; shift ;;
    --request-file)
      [ -z "$REQUEST_MODE" ] || { echo "CODEX_ERROR: request mode specified more than once"; exit 2; }
      REQUEST_MODE="file"; REQUEST_FILE=$2; shift 2 ;;
    --retry-safe) RETRY_SAFE=1; shift ;;
    --poll) POLL=$2; shift 2 ;;
    --recover) RECOVER=$2; shift 2 ;;
    --verify) VERIFY=$2; shift 2 ;;
    --finalize) FINALIZE=$2; shift 2 ;;
    --status) STATUS_ID=$2; shift 2 ;;
    --sweep) SWEEP=1; shift ;;
    --cancel) CANCEL_ID=$2; shift 2 ;;
    --doctor) DOCTOR=1; shift ;;
    --require) REQUIRE=$2; shift 2 ;;
    --poll-budget)
      case "$2" in
        *[!0-9]*) echo "CODEX_ERROR: --poll-budget must be a nonnegative integer, got '$2'" >&2; exit 2 ;;
      esac
      BUDGET=$2; shift 2 ;;
    --footer) FOOTER=1; shift ;;
    --extract-review) EXTRACT=$2; shift 2 ;;
    --record-codex) RECORD_SCRATCH=$2 RECORD_PID=$3; shift 3 ;;
    *) echo "CODEX_ERROR: unknown flag $1" >&2; exit 2 ;;
  esac
done

LIFECYCLE_MODES=0
[ -z "$FINALIZE" ] || LIFECYCLE_MODES=$((LIFECYCLE_MODES + 1))
[ -z "$STATUS_ID" ] || LIFECYCLE_MODES=$((LIFECYCLE_MODES + 1))
[ "$SWEEP" = 0 ] || LIFECYCLE_MODES=$((LIFECYCLE_MODES + 1))
[ -z "$CANCEL_ID" ] || LIFECYCLE_MODES=$((LIFECYCLE_MODES + 1))
[ "$DOCTOR" = 0 ] || LIFECYCLE_MODES=$((LIFECYCLE_MODES + 1))
[ "$LIFECYCLE_MODES" -le 1 ] \
  || { echo "CODEX_ERROR: lifecycle commands cannot be combined" >&2; exit 2; }
if [ "$LIFECYCLE_MODES" -gt 0 ]; then
  [ -z "$REQUEST_MODE$POLL$RECOVER$VERIFY$EXTRACT$RECORD_SCRATCH" ] \
    || { echo "CODEX_ERROR: lifecycle commands cannot be combined with run modes" >&2; exit 2; }
  if [ -n "$FINALIZE" ]; then manifest_lifecycle finalize "$FINALIZE"; exit $?; fi
  if [ -n "$STATUS_ID" ]; then manifest_lifecycle status "$STATUS_ID"; exit $?; fi
  if [ "$SWEEP" = 1 ]; then manifest_lifecycle sweep; exit $?; fi
  if [ -n "$CANCEL_ID" ]; then manifest_lifecycle cancel "$CANCEL_ID"; exit $?; fi
  doctor_probe
  exit $?
fi
[ -z "$REQUIRE" ] \
  || { echo "CODEX_ERROR: --require is valid only with --doctor" >&2; exit 2; }

# Internal: called by the detached run.sh right after spawning its codex child
# so the manifest carries the child's pid identity (attach/cancel/sweep use it).
if [ -n "$RECORD_SCRATCH" ]; then
  manifest_lifecycle record-codex "$RECORD_SCRATCH" "$RECORD_PID"
  exit $?
fi

if [ -n "$REQUEST_MODE" ]; then
  parse_request_envelope "$REQUEST_MODE" "$REQUEST_FILE"
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
fi

# Internal: called by the detached run.sh after codex review exits. Pulls the
# final review text + token usage out of the run's isolated session rollouts
# into last.txt / telemetry (review mode has no -o/--json to capture directly).
if [ -n "$EXTRACT" ]; then
  python3 - "$EXTRACT" <<'PYEOF'
import glob, json, re, sys
S = sys.argv[1]
try:
    log = open(f"{S}/events.jsonl", errors="replace").read()
except OSError:
    log = ""
m = re.search(r'^session id: (\S+)$', log, re.M)
session = m.group(1) if m else "missing"
last, fallback, totals = None, None, {}
for f in sorted(glob.glob(f"{S}/home/sessions/*/*/*/rollout-*.jsonl")):
    file_usage = None
    for line in open(f, errors="replace"):
        try:
            p = (json.loads(line).get("payload") or {})
        except Exception:
            continue
        if p.get("type") == "task_complete" and p.get("last_agent_message"):
            if session != "missing" and session in f:
                last = p["last_agent_message"]
            else:
                fallback = p["last_agent_message"]
        elif p.get("type") == "token_count":
            u = (p.get("info") or {}).get("total_token_usage")
            if u:
                file_usage = u  # last one per file is that session's total
    if file_usage:
        for k, v in file_usage.items():
            totals[k] = totals.get(k, 0) + v
last = last or fallback
if last:
    open(f"{S}/last.txt", "w").write(last)
usage = "missing"
if totals:
    usage = (f"input={totals.get('input_tokens', 0)} "
             f"cached={totals.get('cached_input_tokens', 0)} "
             f"output={totals.get('output_tokens', 0)} "
             f"reasoning={totals.get('reasoning_output_tokens', 0)}")
open(f"{S}/telemetry", "w").write(f"{session}\n{usage}\n")
PYEOF
  exit $?
fi

# Verify mode: which of these session ids did codex-run.sh actually run? Only
# this script writes `ok session=<id>` to usage.log (before the forwarder's
# final message exists), so a model cannot forge it. Prints `<id> ok` or
# `<id> forged` per id — the orchestrator's post-fan-out proof check for the
# ungated Workflow path (SubagentStop hooks don't fire on Workflow legs).
if [ -n "$VERIFY" ]; then
  UL="$WORKER_HOME/usage.log"
  for sid in $(printf '%s' "$VERIFY" | tr ',' ' '); do
    case "$sid" in ''|*[!0-9a-fA-F-]*) echo "$sid forged"; continue ;; esac
    # Positional field match (`<ts> ok session=<id> ...`), never a substring: a
    # run whose --cwd embedded `ok session=<sid> ` would otherwise plant that
    # text in its own log line and self-verify (v3.7 review).
    if awk -v s="session=$sid" '$2=="ok" && $3==s {f=1} END{exit !f}' "$UL" 2>/dev/null; then echo "$sid ok"; else echo "$sid forged"; fi
  done
  exit 0
fi

# Recover mode: re-emit a completed run's caller-contract output from the
# archive (content) + usage.log (telemetry). Deterministic — no model in the
# loop — so a wrapper whose relay was stripped/garbled can regenerate the
# exact footer block instead of retyping from memory (2026-07-08: 4 legs ran
# ok but returned footer-less finals; recovery via cat was gate-denied).
if [ -n "$RECOVER" ]; then
  case "$RECOVER" in
    *[!0-9a-fA-F-]*|'') echo "CODEX_ERROR: --recover takes a session id, got '$RECOVER'"; exit 2 ;;
  esac
  ARCHIVE="$WORKER_HOME/results/$RECOVER.txt"
  [ -f "$ARCHIVE" ] || { echo "CODEX_ERROR: no archived result for session $RECOVER (archive keeps 7 days; check $WORKER_HOME/usage.log for the ok line)"; exit 2; }
  LINE=$(awk -v s="session=$RECOVER" '$2=="ok" && $3==s' "$WORKER_HOME/usage.log" 2>/dev/null | tail -1)
  USAGE=$(printf '%s' "$LINE" | grep -oE 'input=[0-9]+ cached=[0-9]+ output=[0-9]+ reasoning=[0-9]+' | head -1)
  [ -n "$USAGE" ] || USAGE=missing
  BYTES=$(wc -c < "$ARCHIVE")
  if [ "$BYTES" -gt "$RELAY_MAX" ]; then
    echo "[codex-final-file: $ARCHIVE bytes=$BYTES]"
  else
    cat "$ARCHIVE"; echo
  fi
  echo "[codex-session: $RECOVER]"
  echo "[codex-usage: $USAGE]"
  FILES=$(printf '%s' "$LINE" | grep -oE ' files=[0-9]+' | grep -oE '[0-9]+')
  [ -n "$FILES" ] && echo "[codex-files-written: $FILES]"
  exit 0
fi

# Reject garbage before it becomes a real directory or generated shell: an
# interpolated-undefined CWD must never be mkdir'd (2026-07-07 incident), and
# directive values are written inside single quotes in run.sh, so quotes/
# newlines in any value would break out of the generated script.
if [ -z "$POLL" ]; then
  case "$CWD" in
    undefined|null|NaN|'') echo "CODEX_ERROR: invalid --cwd '$CWD' (unresolved orchestrator variable?)" >&2; exit 2 ;;
    /*) : ;;
    *) echo "CODEX_ERROR: --cwd must be an absolute path, got '$CWD'" >&2; exit 2 ;;
  esac
  case "/$CWD/" in
    */undefined/*|*/null/*|*/NaN/*) echo "CODEX_ERROR: --cwd '$CWD' contains an unresolved placeholder segment" >&2; exit 2 ;;
  esac
  if [ -n "$OUTPUT_FILE" ]; then
    case "$OUTPUT_FILE" in
      /*) : ;;
      *) echo "CODEX_ERROR: --output-file must be an absolute path, got '$OUTPUT_FILE'" >&2; exit 2 ;;
    esac
    case "$OUTPUT_FILE" in
      *[[:space:]]*) echo "CODEX_ERROR: --output-file must not contain whitespace: '$OUTPUT_FILE'" >&2; exit 2 ;;
    esac
    case "/$OUTPUT_FILE/" in
      */undefined/*|*/null/*|*/NaN/*) echo "CODEX_ERROR: --output-file '$OUTPUT_FILE' contains an unresolved placeholder segment" >&2; exit 2 ;;
    esac
    if [ -e "$OUTPUT_FILE" ] || [ -L "$OUTPUT_FILE" ]; then
      [ -f "$OUTPUT_FILE" ] && [ ! -L "$OUTPUT_FILE" ] \
        || { echo "CODEX_ERROR: --output-file '$OUTPUT_FILE' exists but is a symlink or non-regular file" >&2; exit 2; }
    fi
    # Fail fast on a symlinked ancestor before spending a codex run; delivery
    # re-checks the same invariant against mid-run planting (v4.0.1).
    [ "$(realpath -m -- "$OUTPUT_FILE" 2>/dev/null)" = "$OUTPUT_FILE" ] \
      || { echo "CODEX_ERROR: --output-file '$OUTPUT_FILE' resolves through a symlink; pass the fully-resolved path" >&2; exit 2; }
  fi
  for v in "$CWD" "$MODEL" "$RESUME" "$MCP" "$EFFORT" "$SANDBOX" "$REVIEW" "$OUTPUT_FILE"; do
    case "$v" in *\'*|*\"*|*\`*|*\$*|*\\*|*$'\n'*|*$'\r'*)
      echo "CODEX_ERROR: directive value contains shell metacharacters: $v" >&2; exit 2 ;;
    esac
  done
  # ultra (codex's multi-agent orchestration profile) is DISABLED as a launch
  # value: benched poorly 2026-07-13. Callers pick a reasoning tier per task
  # and put any subagent-orchestration protocol explicitly in the task text.
  # Re-enable by restoring `ultra` to this case if a future bench clears it.
  case "$EFFORT" in
    none|low|medium|high|xhigh|max) : ;;
    ultra) echo "CODEX_ERROR: EFFORT ultra is disabled (multi-agent profile, benched poor 2026-07-13) — pick a reasoning tier (none|low|medium|high|xhigh|max) for the task and spell out any subagent orchestration protocol in the task text" >&2; exit 2 ;;
    *) echo "CODEX_ERROR: invalid --effort '$EFFORT'" >&2; exit 2 ;;
  esac
  case "$SANDBOX" in read-only|workspace-write) : ;; *) echo "CODEX_ERROR: invalid --sandbox '$SANDBOX'" >&2; exit 2 ;; esac
  # --network only toggles sandbox_workspace_write.network_access, so pairing it
  # with read-only was a silent no-op (v3.7 audit) — reject it loudly.
  [ "$NETWORK" = 1 ] && [ "$SANDBOX" = read-only ] && { echo "CODEX_ERROR: --network requires --sandbox workspace-write (read-only sandbox has no network path)" >&2; exit 2; }
  if [ -n "$REVIEW" ]; then
    case "$REVIEW" in
      uncommitted|custom) : ;;
      base=?*) case "${REVIEW#base=}" in *[!A-Za-z0-9._/-]*) echo "CODEX_ERROR: invalid --review base branch '${REVIEW#base=}'" >&2; exit 2 ;; esac ;;
      commit=?*) case "${REVIEW#commit=}" in *[!0-9a-fA-F]*) echo "CODEX_ERROR: invalid --review commit sha '${REVIEW#commit=}'" >&2; exit 2 ;; esac ;;
      *) echo "CODEX_ERROR: invalid --review '$REVIEW' (use uncommitted|custom|base=<branch>|commit=<sha>)" >&2; exit 2 ;;
    esac
    [ -n "$RESUME" ] && { echo "CODEX_ERROR: --review cannot combine with --resume" >&2; exit 2; }
    [ -n "$MCP" ] && { echo "CODEX_ERROR: --review cannot combine with --mcp" >&2; exit 2; }
    [ "$NETWORK" = 1 ] && { echo "CODEX_ERROR: --review cannot combine with --network" >&2; exit 2; }
    [ -n "$SCHEMA$SCHEMA_FILE" ] && [ "$REVIEW" != custom ] && { echo "CODEX_ERROR: --schema requires --review custom (targeted reviews use codex's canned prompt)" >&2; exit 2; }
    SANDBOX=read-only   # the review harness is read-only by construction
  fi
  # Request mode requires an EXISTING dir unless CREATE_CWD opts in — that
  # guard is what catches typo'd/undefined CWDs. LEGACY FLAG launches keep the
  # v3.9 auto-create: a cached v3.9 forwarder cannot know --create-cwd, and
  # rejecting its research/image scratch legs would break the one-release
  # transition window (Stage E; the undefined/null/NaN guards above still
  # reject interpolation garbage in both modes).
  if [ ! -d "$CWD" ]; then
    if [ "$SANDBOX" = workspace-write ] && { [ "$CREATE_CWD" = 1 ] || [ -z "$REQUEST_MODE" ]; }; then
      :
    elif [ "$SANDBOX" = workspace-write ]; then
      echo "CODEX_ERROR: --cwd '$CWD' does not exist (workspace-write requires an existing directory unless CREATE_CWD: on is set)" >&2; exit 2
    else
      echo "CODEX_ERROR: --cwd '$CWD' does not exist (read-only/review requires an existing directory)" >&2; exit 2
    fi
  fi
fi

output_fingerprint() { # $1=destination -> sha256, ABSENT, SPECIAL, or UNREADABLE
  local sum
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; then
    printf '%s\n' SPECIAL
  elif [ ! -e "$1" ]; then
    printf '%s\n' ABSENT
  elif sum=$(sha256sum -- "$1" 2>/dev/null); then
    printf '%s\n' "${sum%% *}"
  else
    printf '%s\n' UNREADABLE
  fi
}

write_output_atomic() { # $1=source $2=destination
  local dir tmp
  dir=$(dirname "$2")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.codex-output.XXXXXX" 2>/dev/null) || return 1
  if cp "$1" "$tmp" 2>/dev/null && mv -f "$tmp" "$2" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

scan_events() { # $1=scratch -> sets SESSION, USAGE
  SESSION="missing" USAGE="missing"
  if [ -f "$1/telemetry" ]; then   # review mode: written by --extract-review
    SESSION=$(sed -n 1p "$1/telemetry"); USAGE=$(sed -n 2p "$1/telemetry")
    [ -n "$SESSION" ] || SESSION="missing"; [ -n "$USAGE" ] || USAGE="missing"
    return 0
  fi
  [ -f "$1/events.jsonl" ] || return 0
  SESSION=$(grep -m1 -oE '"(thread_id|session_id)":"[^"]*"' "$1/events.jsonl" | cut -d'"' -f4)
  [ -n "$SESSION" ] || SESSION="missing"
  # Sum usage across ALL attempts: the retry loop truncates events.jsonl each
  # pass, so a per-attempt turn.completed is stashed in usage_parts (v3.7 audit:
  # failed-retry tokens used to vanish from the footer). Fall back to the final
  # events.jsonl when no parts file exists (single attempt / old scratch).
  local src="$1/usage_parts"; [ -f "$src" ] || src="$1/events.jsonl"
  if grep -q '"type":"turn.completed"' "$src" 2>/dev/null; then
    sum() { grep -o "\"$1\":[0-9]*" "$src" 2>/dev/null | grep -o '[0-9]*$' | awk '{s+=$1} END{print s+0}'; }
    USAGE="input=$(sum input_tokens) cached=$(sum cached_input_tokens) output=$(sum output_tokens) reasoning=$(sum reasoning_output_tokens)"
  fi
}

load_finalized_manifest() { # $1=scratch -> 0 terminal, 1 no manifest, 2 corrupt, 3 pending
  local path="$WORKER_HOME/attempts/${1##*/}.json" raw rc tries=0
  local -a manifest_data
  MANIFEST_PRESENT=0 FINALIZED_STATE="" MANIFEST_ARCHIVE=""
  MANIFEST_DELIVERY="" MANIFEST_OUTPUT="" MANIFEST_ERROR=""
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  MANIFEST_PRESENT=1
  while [ "$tries" -lt 100 ]; do
    raw=$(manifest_lifecycle read "$1" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      mapfile -t manifest_data <<< "$raw"
      FINALIZED_STATE=${manifest_data[0]:-failed}
      SESSION=${manifest_data[1]:-missing}
      USAGE=${manifest_data[2]:-missing}
      MANIFEST_ARCHIVE=${manifest_data[3]:--}
      MANIFEST_DELIVERY=${manifest_data[4]:--}
      MANIFEST_OUTPUT=${manifest_data[5]:--}
      MANIFEST_ERROR=${manifest_data[6]:--}
      [ "$MANIFEST_ARCHIVE" != - ] || MANIFEST_ARCHIVE=""
      [ "$MANIFEST_DELIVERY" != - ] || MANIFEST_DELIVERY=""
      [ "$MANIFEST_OUTPUT" != - ] || MANIFEST_OUTPUT=""
      [ "$MANIFEST_ERROR" != - ] || MANIFEST_ERROR=""
      return 0
    fi
    [ "$rc" -eq 4 ] || return 2
    tries=$((tries + 1))
    sleep 0.05
  done
  return 3
}

map_finalized_state() { # dynamic scope: assigns emit_block's status/keep
  case "$FINALIZED_STATE" in
    succeeded) status=ok ;;
    failed|orphaned|cancelled) status=error; keep=yes ;;
  esac
}

files_written() { # $1=scratch -> prints changed-file list (workspace-write only)
  [ "$(sed -n 2p "$1/meta")" = workspace-write ] || return 0
  find "$(sed -n 1p "$1/meta")" \( -name .git -o -name node_modules \) -prune \
    -o -type f -newer "$1/marker" -print 2>/dev/null | head -200
}

prepare_final() { # $1=scratch -> sets RELAY(inline|file), FINAL_FILE, BYTES, ARCHIVE, KEEP_SCRATCH
  RELAY=inline FINAL_FILE="" ARCHIVE="${MANIFEST_ARCHIVE:-}"
  BYTES=$(wc -c < "$1/last.txt" 2>/dev/null || echo 0)
  if [ "$MANIFEST_PRESENT" = 1 ] && [ -n "$MANIFEST_OUTPUT" ] && [ -n "$MANIFEST_DELIVERY" ]; then
    # v4 manifest-backed run: delivery already happened inside --finalize
    # (runner-owned, per-destination lock, terminal state reflects it). This
    # path only emits what the manifest recorded — it never re-delivers.
    # A terminal manifest with output_file but NO recorded delivery predates
    # the finalize-owned delivery (pre-Stage-E shape) and falls through to
    # the legacy locked delivery below instead of a false failure.
    case "$MANIFEST_DELIVERY" in
      delivered)
        RELAY=file FINAL_FILE="$MANIFEST_OUTPUT"
        BYTES=$(wc -c < "$MANIFEST_OUTPUT" 2>/dev/null || echo "$BYTES") ;;
      preserved-worker-file)
        OUTPUT_CONFLICT=1 OUTPUT_CONFLICT_PATH="$MANIFEST_OUTPUT"
        RELAY=file FINAL_FILE="$ARCHIVE" ;;
      *)
        OUTPUT_FILE_FAILED=1 KEEP_SCRATCH=1
        ERROR_MSG="requested --output-file '$MANIFEST_OUTPUT' has no recorded delivery outcome; codex ran (session $SESSION), content is at ${ARCHIVE:-$1/last.txt}" ;;
    esac
    return 0
  fi
  local out; out=$(sed -n 3p "$1/meta" 2>/dev/null)
  if [ -z "$ARCHIVE" ] && [ "$SESSION" != missing ] && mkdir -p "$WORKER_HOME/results" 2>/dev/null \
     && cp "$1/last.txt" "$WORKER_HOME/results/.$SESSION.tmp" 2>/dev/null \
     && mv "$WORKER_HOME/results/.$SESSION.tmp" "$WORKER_HOME/results/$SESSION.txt" 2>/dev/null; then
    ARCHIVE="$WORKER_HOME/results/$SESSION.txt"
  fi
  if [ -n "$out" ]; then
    # LEGACY (pre-manifest scratch): serialize fingerprint->write on the same
    # per-destination lock file the v4 finalizer uses, so a transition-window
    # legacy poll cannot race a v4 delivery to one destination (Stage E).
    local before now ofd="" out_key
    out_key=$(printf '%s' "$out" | sha256sum | cut -c1-16)
    mkdir -p "$WORKER_HOME/output-locks" 2>/dev/null
    if exec {ofd}<>"$WORKER_HOME/output-locks/$out_key.lock" 2>/dev/null \
       && flock "$ofd" 2>/dev/null; then
      :
    else
      # Fail CLOSED: delivering unlocked could race a v4 finalizer writing
      # the same destination (re-review round 2). The scratch keeps the
      # content; nothing is lost by refusing.
      [ -z "${ofd:-}" ] || exec {ofd}>&-
      OUTPUT_FILE_FAILED=1 KEEP_SCRATCH=1
      ERROR_MSG="cannot take the per-destination lock for --output-file '$out'; codex ran (session $SESSION), content is at ${ARCHIVE:-$1/last.txt}"
      return 0
    fi
    before=$(sed -n 4p "$1/meta" 2>/dev/null)
    now=$(output_fingerprint "$out")
    # A v3.9 scratch has only three meta lines. It predates ownership tracking,
    # so retain its established OUTPUT_FILE finalization behavior when polled.
    [ -n "$before" ] || before="$now"
    if [ "$before" != "$now" ] && [ -n "$ARCHIVE" ]; then
      # Codex wrote the requested destination during the run. Preserve its
      # artifact and relay the archived final message as a separate fact line.
      OUTPUT_CONFLICT=1 OUTPUT_CONFLICT_PATH="$out"
      RELAY=file FINAL_FILE="$ARCHIVE"
    elif [ "$before" = "$now" ] && write_output_atomic "$1/last.txt" "$out"; then
      RELAY=file FINAL_FILE="$out"
    else
      OUTPUT_FILE_FAILED=1 KEEP_SCRATCH=1
      ERROR_MSG="requested --output-file '$out' could not be finalized without clobbering or write failure; codex ran (session $SESSION), content is at ${ARCHIVE:-$1/last.txt}"
    fi
    [ -z "$ofd" ] || exec {ofd}>&-
  elif [ "$FOOTER" = 1 ] && [ "$BYTES" -gt "$RELAY_MAX" ]; then
    # Oversized inline relay is the proven haiku failure mode — NEVER fall
    # back to it. If the archive copy failed, point at the scratch copy and
    # keep the scratch dir alive instead.
    if [ -n "$ARCHIVE" ]; then RELAY=file FINAL_FILE="$ARCHIVE"
    else RELAY=file FINAL_FILE="$1/last.txt" KEEP_SCRATCH=1; fi
  fi
}

emit_final_content() { # $1=scratch — envelope or inline last.txt (shared by both emitters)
  if [ "$RELAY" = file ]; then
    [ "$OUTPUT_CONFLICT" = 1 ] && echo "[codex-output-conflict: $OUTPUT_CONFLICT_PATH preserved worker-written; final-message at $ARCHIVE]"
    echo "[codex-final-file: $FINAL_FILE bytes=$BYTES]"
  else
    cat "$1/last.txt"; echo
  fi
}

emit_footer() { # $1=status $2=scratch
  if [ "$1" = ok ]; then
    emit_final_content "$2"
    echo "[codex-session: $SESSION]"
    echo "[codex-usage: $USAGE]"
    [ -n "$FILES_N" ] && echo "[codex-files-written: $FILES_N]"
  elif [ "$1" = running ]; then
    echo "CODEX_RUNNING: re-invoke with: $0 --footer --poll $2"
  elif [ -n "${ERROR_MSG:-}" ]; then
    echo "CODEX_ERROR: $ERROR_MSG"
    echo "[codex-scratch: $2]"
  else
    echo "CODEX_ERROR: codex exec failed (exit $(cat "$2/exit" 2>/dev/null || echo '?'), usage=$USAGE). events tail:"
    tail -30 "$2/events.jsonl" 2>/dev/null
    echo "[codex-scratch: $2]"
  fi
}

emit_envelope() { # $1=status $2=scratch $3=keep
  echo "===CODEX_RESULT==="
  echo "STATUS: $1"
  echo "SESSION: $SESSION"
  echo "USAGE: $USAGE"
  [ "$3" = yes ] && echo "SCRATCH: $2"
  if [ "$1" = ok ] && [ "$(sed -n 2p "$2/meta")" = workspace-write ]; then
    local files; files=$(files_written "$2")
    echo "FILES_WRITTEN: $(printf '%s' "$files" | grep -c .)"
    [ -n "$files" ] && printf '%s\n' "$files"
  fi
  echo "===FINAL==="
  if [ "$1" = ok ]; then
    emit_final_content "$2"
  elif [ "$1" = running ]; then
    echo "still running; re-invoke with: codex-run.sh --poll $2"
  elif [ -n "${ERROR_MSG:-}" ]; then
    echo "CODEX_ERROR: $ERROR_MSG"
  else
    echo "CODEX_ERROR: codex exec failed (exit $(cat "$2/exit" 2>/dev/null || echo '?'), usage=$USAGE). events tail:"
    tail -30 "$2/events.jsonl" 2>/dev/null
  fi
  echo "===END==="
}

emit_block() { # $1=status $2=scratch $3=keep (yes|no)
  local status=$1 S=$2 keep=$3 legacy_usage_log=0
  RELAY=inline FINAL_FILE="" BYTES=0 ARCHIVE="" KEEP_SCRATCH=0 FILES_N="" ERROR_MSG="" OUTPUT_FILE_FAILED=""
  OUTPUT_CONFLICT=0 OUTPUT_CONFLICT_PATH=""
  SESSION=missing USAGE=missing MANIFEST_ARCHIVE="" MANIFEST_DELIVERY="" MANIFEST_OUTPUT="" MANIFEST_ERROR=""
  if [ "$status" = running ]; then
    scan_events "$S"
    # An attached run whose leader AND codex child both died will never
    # finalize itself — reconcile it now so poll loops terminate instead of
    # reporting running forever (Stage E; single-target sweep). The run may
    # ALSO have gone terminal between find-live's unlocked snapshot and this
    # emit — probe for a terminal manifest (single non-blocking read; the
    # full loader would wait 5s on a live run) and emit the real result
    # instead of a stale CODEX_RUNNING (re-review 2026-07-14).
    manifest_lifecycle sweep "$S" >/dev/null 2>&1
    if manifest_lifecycle read "$S" >/dev/null 2>&1 && load_finalized_manifest "$S"; then
      map_finalized_state
    fi
  else
    load_finalized_manifest "$S"
    case $? in
      0) map_finalized_state ;;
      1)
        # Compatibility for scratches launched by versions that predate manifests.
        scan_events "$S"
        legacy_usage_log=1
        ;;
      3)
        # Manifest exists but is not terminal. A live finalizer means the run
        # is genuinely unfinished — report running, never a downgraded error
        # (Stage E: a slow finalizer turned success into CODEX_ERROR/exit 3).
        # A dead one will never finish — finalize synchronously and re-read.
        if manifest_lifecycle alive "$S" >/dev/null 2>&1; then
          status=running keep=yes
          scan_events "$S"
        elif manifest_lifecycle finalize "$S" >/dev/null 2>&1 && load_finalized_manifest "$S"; then
          map_finalized_state
        else
          status=error keep=yes
        fi
        ;;
      *) status=error keep=yes ;;
    esac
  fi
  # ok must always carry real proof: callers gate on a non-missing session.
  if [ "$status" = ok ] && { [ "$USAGE" = missing ] || [ "$SESSION" = missing ]; }; then
    status=error; keep=yes
  fi
  # A manifest-recorded failure (e.g. OUTPUT_FILE delivery) carries its reason.
  if [ "$status" = error ] && [ -n "$MANIFEST_ERROR" ] && [ -z "$ERROR_MSG" ]; then
    ERROR_MSG="$MANIFEST_ERROR (session $SESSION)"
  fi
  [ "$status" = ok ] && prepare_final "$S"
  # A requested OUTPUT_FILE that could not be written is a hard failure, not a
  # silent relay fallback (v3.7 audit) — codex succeeded but the artifact is missing.
  [ -n "$OUTPUT_FILE_FAILED" ] && { status=error; keep=yes; }
  # FILES_N feeds the footer emitter + usage.log; only footer mode uses it, and
  # envelope mode runs its own files_written for the file LIST — computing it
  # here for envelope mode too would traverse the workspace twice (v3.5 review).
  [ "$FOOTER" = 1 ] && [ "$status" = ok ] && [ "$(sed -n 2p "$S/meta")" = workspace-write ] && FILES_N=$(files_written "$S" | grep -c .)
  [ "$KEEP_SCRATCH" = 1 ] && keep=yes
  # New attempts append from --finalize. Preserve the old append only for an
  # in-flight manifest-less scratch so upgrades cannot strand its proof line.
  if [ "$status" != running ] && [ "$legacy_usage_log" = 1 ]; then
    { mkdir -p "$WORKER_HOME" && echo "$(date -Is) $status session=$SESSION $USAGE${FILES_N:+ files=$FILES_N} cwd=$(sed -n 1p "$S/meta" 2>/dev/null)${ARCHIVE:+ file=$ARCHIVE}" >> "$WORKER_HOME/usage.log"; } 2>/dev/null
  fi
  if [ "$FOOTER" = 1 ]; then emit_footer "$status" "$S"; else emit_envelope "$status" "$S" "$keep"; fi
  # A SHARED scratch has two watchers (duplicate-launch convergence): keep it
  # so the slower emitter never reads a half-deleted dir; the launch-time
  # retention sweep removes day-old completed ones.
  [ "$status" = ok ] && [ "$keep" = no ] && [ ! -f "$S/SHARED" ] && rm -rf "$S"
  [ "$status" = running ] || { [ -z "$LAUNCH_PROOF" ] || rm -f "$LAUNCH_PROOF"; }
  [ "$status" = error ] && return 3
  return 0
}

if [ -n "$POLL" ]; then
  S=$POLL
  case "$S" in /tmp/codex-worker.[A-Za-z0-9]*) : ;; *)
    echo "CODEX_ERROR: invalid --poll scratch '$S' (expected runner-created /tmp/codex-worker.*)" >&2; exit 2 ;;
  esac
  [ -d "$S" ] && [ ! -L "$S" ] || { echo "CODEX_ERROR: invalid --poll scratch '$S'" >&2; exit 2; }
  LAUNCH_PROOF="$WORKER_HOME/launches/${S##*/}"
  [ -f "$LAUNCH_PROOF" ] && [ ! -L "$LAUNCH_PROOF" ] \
    || { echo "CODEX_ERROR: unrecognized --poll scratch '$S' (no runner launch proof)" >&2; exit 2; }
  IFS= read -r REGISTERED < "$LAUNCH_PROOF" || REGISTERED=""
  [ "$REGISTERED" = "$S" ] \
    || { echo "CODEX_ERROR: invalid --poll scratch '$S' (launch proof mismatch)" >&2; exit 2; }
  [ -f "$S/meta" ] || { echo "CODEX_ERROR: no launch found at $S" >&2; exit 2; }
else
  S=$(mktemp -d /tmp/codex-worker.XXXXXX)
  if [ -n "$REQUEST_MODE" ]; then
    mv "$REQUEST_STAGE/task.txt" "$S/task.txt" \
      || { echo "CODEX_ERROR: cannot stage parsed task"; rm -rf "$S"; exit 2; }
  else
    cat > "$S/task.txt"
  fi
  if [ -n "$REVIEW" ] && [ "$REVIEW" != custom ]; then
    # Targeted reviews use codex's canned prompt; codex 0.144.0 cannot combine a
    # custom prompt with --uncommitted/--base/--commit. 'custom' reviews the
    # same uncommitted diff with the caller's instructions, so uncommitted +
    # task text converts losslessly instead of failing the leg (live-hit
    # 2026-07-13: a Workflow verify leg died on this).
    if [ -s "$S/task.txt" ]; then
      if [ "$REVIEW" = uncommitted ]; then
        echo "codex-run: REVIEW uncommitted + task text — auto-converted to REVIEW custom" >&2
        REVIEW=custom
      else
        echo "CODEX_ERROR: REVIEW '$REVIEW' cannot take task text on codex 0.144.0 — base=/commit= reviews use codex's canned prompt; drop the task text (only 'uncommitted' auto-converts to custom)" >&2; rm -rf "$S"; exit 2
      fi
    fi
  else
    [ -s "$S/task.txt" ] || { echo "CODEX_ERROR: empty task on stdin" >&2; rm -rf "$S"; exit 2; }
  fi
  # Schema rides in the task text, not --output-schema: codex's native flag
  # demands OpenAI strict mode (additionalProperties:false, all props required),
  # which breaks optional fields and would make codex invent telemetry values.
  if [ -n "$REQUEST_MODE" ] && [ -n "$SCHEMA_FILE" ]; then
    mv "$SCHEMA_FILE" "$S/request-schema" \
      || { echo "CODEX_ERROR: cannot stage request schema"; rm -rf "$S"; exit 2; }
    SCHEMA_FILE="$S/request-schema"
  fi
  if [ -n "$SCHEMA_FILE" ]; then
    SCHEMA=$(cat "$SCHEMA_FILE" 2>/dev/null) || { echo "CODEX_ERROR: cannot read --schema-file $SCHEMA_FILE" >&2; rm -rf "$S"; exit 2; }
  fi
  [ -z "$REQUEST_MODE" ] || rm -f "$S/request-schema"
  [ -n "$SCHEMA" ] && printf '\n\nOutput ONLY a single minified JSON object on one line conforming to this JSON Schema — no markdown fences, no prose before or after:\n%s\n' "$SCHEMA" >> "$S/task.txt"
  # Launch dedup (v3.9): key on task + every launch-shaping directive. NUL can't
  # ride printf portably, so \1 separates task bytes from the directive tuple.
  TASK_HASH=$({ cat "$S/task.txt"; printf '\1%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$MODEL" "$EFFORT" "$SANDBOX" "$CWD" "$NETWORK" "$MCP" "$RESUME" "$REVIEW" "$OUTPUT_FILE" "$CREATE_CWD"; } \
    | sha256sum | cut -c1-16)
  LOCK="$WORKER_HOME/locks/$TASK_HASH.lock"
  mkdir -p "$WORKER_HOME/locks" || { echo "CODEX_ERROR: cannot create $WORKER_HOME/locks" >&2; rm -rf "$S"; exit 2; }
  chmod 700 "$WORKER_HOME/locks" 2>/dev/null || true
  exec 9<> "$LOCK" || { echo "CODEX_ERROR: cannot open launch lock $LOCK" >&2; rm -rf "$S"; exit 2; }
  if ! flock -n 9; then
    PRIOR="" tries=0
    while [ "$tries" -lt 20 ]; do
      IFS=' ' read -r PRIOR _ _ < "$LOCK" 2>/dev/null || PRIOR=""
      [ -n "$PRIOR" ] && break
      tries=$((tries + 1)); sleep 0.05
    done
    exec 9>&-
    case "$PRIOR" in /tmp/codex-worker.[A-Za-z0-9]*) : ;; *) PRIOR="" ;; esac
    if [ -n "$PRIOR" ] && [ -d "$PRIOR" ]; then
      rm -rf "$S"
      echo "codex-run: duplicate launch suppressed — identical task already in flight at $PRIOR (deliberate parallel duplicates need a distinguishing line in the task text)" >&2
      touch "$PRIOR/SHARED" 2>/dev/null
      emit_block running "$PRIOR" yes
      exit 0
    fi
    echo "CODEX_ERROR: identical launch is locked but its owner scratch is unavailable" >&2
    rm -rf "$S"
    exit 2
  fi
  # Holding the flock is NOT proof no identical run is live: a SIGKILLed
  # run.sh releases fd 9 while its codex child keeps working. Converge on any
  # running manifest for this task_hash with a live leader or codex pid
  # instead of spawning a twin (Stage E P1).
  if PRIOR_LIVE=$(manifest_lifecycle find-live "$TASK_HASH" 2>/dev/null); then
    case "$PRIOR_LIVE" in
      /tmp/codex-worker.[A-Za-z0-9]*)
        if [ -d "$PRIOR_LIVE" ]; then
          exec 9>&-
          rm -rf "$S"
          echo "codex-run: duplicate launch suppressed — identical task still live at $PRIOR_LIVE (lock was released by a dead holder; converged via manifest pid identity)" >&2
          touch "$PRIOR_LIVE/SHARED" 2>/dev/null
          emit_block running "$PRIOR_LIVE" yes
          exit 0
        fi ;;
    esac
  fi
  OWNER_START=$(awk '{print $22}' "/proc/$$/stat" 2>/dev/null)
  [ -n "$OWNER_START" ] || OWNER_START=missing
  printf '%s %s %s\n' "$S" "$$" "$OWNER_START" > "$LOCK"
  if [ ! -d "$CWD" ]; then
    if [ "$SANDBOX" = workspace-write ] && { [ "$CREATE_CWD" = 1 ] || [ -z "$REQUEST_MODE" ]; }; then
      mkdir -p "$CWD" \
        || { echo "CODEX_ERROR: cannot create CWD $CWD" >&2; rm -rf "$S"; exit 2; }
    else
      echo "CODEX_ERROR: --cwd '$CWD' disappeared before launch" >&2
      rm -rf "$S"
      exit 2
    fi
  fi
  OUTPUT_BASELINE=""
  if [ -n "$OUTPUT_FILE" ]; then
    OUTPUT_BASELINE=$(output_fingerprint "$OUTPUT_FILE")
    case "$OUTPUT_BASELINE" in
      SPECIAL) echo "CODEX_ERROR: --output-file '$OUTPUT_FILE' became a symlink or non-regular file before launch" >&2; rm -rf "$S"; exit 2 ;;
      UNREADABLE) echo "CODEX_ERROR: cannot fingerprint --output-file '$OUTPUT_FILE' before launch" >&2; rm -rf "$S"; exit 2 ;;
    esac
  fi
  printf '%s\n%s\n%s\n%s\n' "$CWD" "$SANDBOX" "$OUTPUT_FILE" "$OUTPUT_BASELINE" > "$S/meta"
  [ -z "$REQUEST_SHA256" ] || printf 'request_sha256=%s\n' "$REQUEST_SHA256" >> "$S/meta"
  touch "$S/marker" 9>&-
  [ "$FOOTER" = 0 ] || touch "$S/FOOTER" 9>&-
  # Retention: results archive self-prunes; 7 days covers any recovery window.
  # Attempt manifests share the horizon (a 7-day-old running manifest is a
  # dead orphan nothing will ever finalize — no codex run lives for days).
  # output-locks are deliberately NEVER pruned: unlinking a lock file that a
  # finalizer currently holds flocked would let a second finalizer lock a
  # fresh inode at the same path and defeat per-destination serialization
  # (re-review 2026-07-14); they are 0-byte, one per unique destination.
  find "$WORKER_HOME/results" -type f -mtime +7 -delete 2>/dev/null
  find "$WORKER_HOME/attempts" -type f -mtime +7 -delete 2>/dev/null
  # Completed SHARED scratches (duplicate-launch convergence keeps them past
  # the terminal emit) are the only scratches this script parks in /tmp on the
  # ok path — sweep the day-old ones here since nothing else will.
  for d in /tmp/codex-worker.*/; do
    [ -f "$d/SHARED" ] && [ -f "$d/DONE" ] \
      && [ -z "$(find "$d/DONE" -newermt '-1 day' 2>/dev/null)" ] && rm -rf "$d"
  done 2>/dev/null

  if [ -n "$REVIEW" ]; then
    # Isolated CODEX_HOME: session rollouts are this run's only, so the
    # extractor can't pick up a concurrent run's telemetry.
    mkdir -p "$S/home"
    cp "$HOME/.codex/auth.json" "$S/home/auth.json" 2>/dev/null
    HOME_LINE="export CODEX_HOME='$S/home'"
    case "$REVIEW" in
      uncommitted) RFLAGS="--uncommitted" ;;
      custom)      RFLAGS="-" ;;
      base=*)      RFLAGS="--base '${REVIEW#base=}'" ;;
      commit=*)    RFLAGS="--commit '${REVIEW#commit=}'" ;;
    esac
    CMD="codex review -c model='$MODEL' -c model_reasoning_effort='$EFFORT' $RFLAGS"
    if [ "$REVIEW" = custom ]; then CMD="$CMD < '$S/task.txt'"; else CMD="$CMD < /dev/null"; fi
    CMD="$CMD > '$S/events.jsonl' 2>&1"
    POST_CMD="'$SELF' --extract-review '$S' >/dev/null 2>&1"
  else
    # Minimal CODEX_HOME unless MCP servers are needed (they live in the full config).
    HOME_LINE=""
    if [ -z "$MCP" ] && [ -d "$WORKER_HOME" ]; then
      cp -u "$HOME/.codex/auth.json" "$WORKER_HOME/auth.json" 2>/dev/null
      HOME_LINE="export CODEX_HOME='$WORKER_HOME'"
    fi
    if [ -n "$RESUME" ]; then
      # resume has no --sandbox flag; enforce the directives via config overrides.
      CMD="codex exec resume '$RESUME' -m '$MODEL' -c model_reasoning_effort='$EFFORT' -c sandbox_mode='$SANDBOX' --skip-git-repo-check --json"
    else
      CMD="codex exec -m '$MODEL' -c model_reasoning_effort='$EFFORT' --sandbox '$SANDBOX' -C '$CWD' --skip-git-repo-check --json"
    fi
    [ "$NETWORK" = 1 ] && CMD="$CMD -c sandbox_workspace_write.network_access=true"
    if [ -n "$MCP" ]; then
      for m in $(printf '%s' "$MCP" | tr ',' ' '); do
        CMD="$CMD -c 'mcp_servers.$m.default_tools_approval_mode=\"approve\"'"
      done
    fi
    # Task rides on stdin (file redirect): argv would cap it at MAX_ARG_STRLEN
    # (~128KiB) and an open-but-empty stdin is the codex#20919 hang.
    CMD="$CMD -o '$S/last.txt' < '$S/task.txt' > '$S/events.jsonl' 2>&1"
    POST_CMD=":"
  fi

  OTHER_LEFT=0
  case "$CWD" in /tmp/*) RETRY_SAFE=1 ;; esac
  { [ "$SANDBOX" = read-only ] || [ "$RETRY_SAFE" = 1 ]; } && OTHER_LEFT=1

  cat > "$S/run.sh" <<RUNNER
#!/usr/bin/env bash
pid_start=\$(awk '{print \$22}' "/proc/\$\$/stat" 2>/dev/null 9>&-)
[ -n "\$pid_start" ] || pid_start=missing
printf '%s %s %s\n' '$S' "\$\$" "\$pid_start" > '$LOCK'
echo \$\$ > '$S/pid'
echo "\$pid_start" > '$S/pid_start'
manifest_wait=500
while [ ! -f '$S/MANIFEST_READY' ] && [ \$manifest_wait -gt 0 ]; do
  manifest_wait=\$((manifest_wait-1)); sleep 0.01 9>&-
done
if [ ! -f '$S/MANIFEST_READY' ]; then
  echo 125 > '$S/exit'; touch '$S/DONE' 9>&-
  exec bash '$SELF' --finalize '$S'
fi
cd '$CWD' || {
  echo 127 > '$S/exit'; touch '$S/DONE' 9>&-
  exec bash '$SELF' --finalize '$S'
}
$HOME_LINE
rl_left=2; other_left=$OTHER_LEFT
while :; do
  rm -f '$S/last.txt' '$S/telemetry' 9>&-
  # The child records ITSELF (\$BASHPID) before exec'ing codex — exec keeps
  # the pid and /proc starttime, so the manifest carries the codex identity
  # from the instant codex exists. This closes the spawn-to-record window:
  # a SIGKILLed leader can no longer strand an unrecorded live codex, and a
  # child killed before recording never reaches exec (re-review residual,
  # closed 2026-07-14).
  { bash '$SELF' --record-codex '$S' "\$BASHPID" >/dev/null 2>&1 9>&- || exit 125; exec $CMD; } 9>&- &
  codex_pid=\$!
  wait "\$codex_pid"
  rc=\$?
  grep -o '"type":"turn.completed".*' '$S/events.jsonl' 2>/dev/null 9>&- | tail -1 9>&- >> '$S/usage_parts'
  $POST_CMD 9>&-
  if [ \$rc -eq 0 ] && [ -s '$S/last.txt' ]; then echo 0 > '$S/exit'; break; fi
  # Transient-classify only real nonzero exits: on rc=0+empty-result the log
  # tail is model/prompt text, and task text quoting these tokens has caused
  # live misclassification. A failed loop must never write exit 0.
  if [ \$rc -ne 0 ] && tail -n 40 '$S/events.jsonl' 9>&- | grep -qiE 'rate_limit|usage_limit|overloaded|too many requests|"429"' 9>&-; then
    if [ \$rl_left -gt 0 ]; then rl_left=\$((rl_left-1)); sleep \$((RANDOM%16+15)) 9>&-; continue; fi
  elif [ \$other_left -gt 0 ]; then other_left=0; continue; fi
  [ \$rc -eq 0 ] && rc=1
  echo \${rc:-1} > '$S/exit'; break
done
touch '$S/DONE' 9>&-
exec bash '$SELF' --finalize '$S'
RUNNER
  chmod +x "$S/run.sh"
  # Polling is a privileged continuation of a runner-created launch.  Keep the
  # registration outside /tmp so a forwarder that can stage schema data there
  # cannot manufacture a completed scratch and make emit_block log a fake ok.
  mkdir -p "$WORKER_HOME/launches" || { echo "CODEX_ERROR: cannot create $WORKER_HOME/launches" >&2; rm -rf "$S"; exit 2; }
  chmod 700 "$WORKER_HOME" "$WORKER_HOME/launches" 2>/dev/null || true
  LAUNCH_PROOF="$WORKER_HOME/launches/${S##*/}"
  proof_tmp="$LAUNCH_PROOF.tmp.$$"
  if (umask 077; printf '%s\n' "$S" > "$proof_tmp") && mv "$proof_tmp" "$LAUNCH_PROOF"; then
    :
  else
    rm -f "$proof_tmp"
    echo "CODEX_ERROR: cannot register runner launch" >&2
    rm -rf "$S"
    exit 2
  fi
  find "$WORKER_HOME/launches" -type f -mtime +7 -delete 2>/dev/null
  nohup setsid bash "$S/run.sh" >/dev/null 2>&1 &
  SPAWN_PID=$!
  spawn_tries=0 RUN_PID="" RUN_START=""
  while [ "$spawn_tries" -lt 200 ]; do
    if [ -s "$S/pid" ] && [ -s "$S/pid_start" ]; then
      IFS= read -r RUN_PID < "$S/pid" || RUN_PID=""
      IFS= read -r RUN_START < "$S/pid_start" || RUN_START=""
      [ -n "$RUN_PID" ] && [ -n "$RUN_START" ] && break
    fi
    spawn_tries=$((spawn_tries + 1))
    sleep 0.01 9>&-
  done
  case "$RUN_PID:$RUN_START" in
    *[!0-9:]*|:|:*|*:) RUN_PID="" ;;
  esac
  if [ -z "$RUN_PID" ] || [ "$(awk '{print $22}' "/proc/$RUN_PID/stat" 2>/dev/null 9>&-)" != "$RUN_START" ]; then
    kill -KILL -- "-$SPAWN_PID" 2>/dev/null 9>&- || kill -KILL "$SPAWN_PID" 2>/dev/null 9>&- || true
    exec 9>&-
    rm -f "$LAUNCH_PROOF"
    rm -rf "$S"
    echo "CODEX_ERROR: detached runner did not publish a stable pid identity" >&2
    exit 3
  fi
  if ! manifest_lifecycle init "$S" "$TASK_HASH" "$CWD" "$SANDBOX" "$MODEL" "$EFFORT" \
      "$RUN_PID" "$RUN_START" "$OUTPUT_FILE" "$OUTPUT_BASELINE" "$REQUEST_SHA256"; then
    kill -TERM -- "-$RUN_PID" 2>/dev/null 9>&- || true
    kill -KILL -- "-$RUN_PID" 2>/dev/null 9>&- || true
    exec 9>&-
    rm -f "$LAUNCH_PROOF"
    rm -rf "$S"
    exit 3
  fi
  touch "$S/MANIFEST_READY" 9>&-
  # The detached run is now the sole lock holder. Its inherited fd closes on
  # exit or death; child codex/sleep processes explicitly do not inherit it.
  exec 9>&-
fi

end=$((SECONDS + BUDGET))
while [ ! -f "$S/DONE" ] && [ $SECONDS -lt $end ]; do sleep 1; done

if [ ! -f "$S/DONE" ]; then
  emit_block running "$S" yes
  exit $?
elif [ "$(cat "$S/exit" 2>/dev/null)" = 0 ]; then
  emit_block ok "$S" no
  exit $?
else
  emit_block error "$S" yes
  exit $?
fi
