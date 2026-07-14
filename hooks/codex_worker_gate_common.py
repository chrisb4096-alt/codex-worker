"""Shared shell classification for the codex-worker enforcement hooks."""

from __future__ import annotations

import os
import re
import shlex


# The absolute form must be the INSTALLED runner under this user's real HOME.
# A suffix match (any path ending in .claude/agents/bin/codex-run.sh) lets a
# workspace-local fake runner — e.g. <repo>/.claude/agents/bin/codex-run.sh —
# execute arbitrary code and emit stdout the stop-gate binds as proof
# (mirror-gate review 2026-07-14, high).
RUNNER_CALL = re.compile(
    r"^\s*(?:~|\$HOME|" + re.escape(os.path.expanduser("~"))
    + r")/\.claude/agents/bin/codex-run\.sh(?:\s|$)"
)
RUNNER_DANGER = re.compile(r"[`<>]|\$\((?!pwd\))")
# --verify only prints ok/forged (no [codex-session:] footer, no content) and
# --extract-review post-processes a prior run — neither is a fresh forward, so
# neither may bind proof. --recover is DELIBERATELY excluded from this set: it
# re-emits a completed run's real archived content + footer through the runner
# (deterministic, runner-owned, and only when the archive genuinely exists), so
# its tool_result IS valid forwarding proof. The stop-gate's own stripped-relay
# remedy tells the forwarder to run it, and a cross-session recover leg would
# otherwise be blocked as "not emitted by this transcript" (v3.7 high review).
PROOFLESS_RUNNER_FLAGS = {"--verify", "--extract-review"}


def _heredoc_on_line(line: str) -> tuple[str, bool] | None:
    """Return the first real, unquoted heredoc delimiter on *line*."""

    quote: str | None = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == "\\" and i + 1 < len(line):
                i += 2
                continue
            if c == '"':
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < len(line):
            i += 2
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            continue
        if c == "#" and (i == 0 or line[i - 1].isspace()):
            break
        if line.startswith("<<", i):
            m = re.match(
                r"<<(?P<tabs>-?)[ \t]*(?:'(?P<sq>\w+)'|\"(?P<dq>\w+)\"|(?P<bare>\w+))",
                line[i:],
            )
            if m:
                return (m.group("sq") or m.group("dq") or m.group("bare"),
                        m.group("tabs") == "-")
        i += 1
    return None


def strip_heredocs(command: str) -> str:
    """Remove actual heredoc bodies while retaining their command headers."""

    lines, out, i = command.split("\n"), [], 0
    while i < len(lines):
        header = lines[i]
        out.append(header)
        spec = _heredoc_on_line(header)
        i += 1
        if spec:
            delimiter, strip_tabs = spec
            while i < len(lines):
                candidate = lines[i].lstrip("\t") if strip_tabs else lines[i]
                if candidate == delimiter:
                    i += 1
                    break
                i += 1
    return "\n".join(out)


def shell_segments(command: str) -> list[str]:
    normalized = strip_heredocs(command or "")
    normalized = re.sub(r"\\\n\s*", " ", normalized)
    return [segment.strip() for segment in re.split(r"[;\n|&]+", normalized)]


def runner_seg_ok(segment: str, *, proof_only: bool = False) -> bool:
    """Classify a runner command; proof mode accepts only launch/poll forms."""

    if not RUNNER_CALL.match(segment) or RUNNER_DANGER.search(segment):
        return False
    if proof_only:
        try:
            argv = shlex.split(segment)
        except ValueError:
            return False
        if any(arg in PROOFLESS_RUNNER_FLAGS for arg in argv[1:]):
            return False
    return True


def runner_invoked(command: str, *, proof_only: bool = False) -> bool:
    return any(runner_seg_ok(segment, proof_only=proof_only)
               for segment in shell_segments(command))


def recover_invoked(command: str) -> bool:
    """True when a runner SEGMENT's argv carries --recover.

    Argv-level on heredoc-stripped segments, never a raw-text search: the
    prompt body routinely discusses the runner (this repo's own tasks), so a
    `--recover` inside a heredoc misclassified a genuine launch as a recover
    and refused to bind its session (mirror-gate round 7, high#2). The runner
    enters recover mode only on the exact `--recover` argv token (its case
    branch takes no `=` form), so argv membership is the faithful test.
    Anything the static split cannot resolve — an unparseable segment, or a
    `$var` argv token that could expand to --recover at run time — classifies
    as recover: over-classification only withholds proof binding
    (fail-closed); under-classification would let a recover's re-emitted
    foreign footer bind as launch proof."""

    for segment in shell_segments(command):
        if not RUNNER_CALL.match(segment) or RUNNER_DANGER.search(segment):
            continue
        try:
            argv = shlex.split(segment)
        except ValueError:
            return True
        if any(arg == "--recover" or "$" in arg for arg in argv[1:]):
            return True
    return False


def poll_scratch(command: str) -> str | None:
    """Return the runner segment's `--poll <scratch>` argument, or None.

    Argv-level like recover_invoked. The stop-gate uses this to bind a poll's
    emitted footer to a scratch THIS transcript's own launch printed: without
    the binding, a leg that never launched could poll another (same-UID)
    session's registered scratch and relay that run's private result under an
    authentic footer (security review round 8, 2026-07-14, high)."""

    for segment in shell_segments(command):
        if not RUNNER_CALL.match(segment) or RUNNER_DANGER.search(segment):
            continue
        try:
            argv = shlex.split(segment)
        except ValueError:
            continue
        for i in range(1, len(argv) - 1):
            if argv[i] == "--poll":
                return argv[i + 1]
    return None


def simple_shell_variables(text: str) -> list[str] | None:
    """Return simple variable references, or None for any other dollar form."""

    names: list[str] = []
    i = 0
    while i < len(text):
        if text.startswith("$(pwd)", i):
            i += len("$(pwd)")
            continue
        if text[i] != "$":
            i += 1
            continue
        m = re.match(r"\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})", text[i:])
        if not m:
            return None
        names.append(m.group(1) or m.group(2))
        i += len(m.group(0))
    return names
