#!/usr/bin/env python3
"""PreToolUse gate: enforce the codex-worker bright line in real time.

Fires on every Bash call (settings matcher: Bash). Acts only when the calling
agent is a codex-worker forwarder — subagent PreToolUse payloads carry
`agent_type` (verified live on this Claude Code build, 2026-07-07). The
command is validated SEGMENT BY SEGMENT (heredoc bodies stripped first — task
text is data, not commands): the whole call must be one of exactly three v4
shapes — the `--parse-request` launch, a runner-authored `--poll`, or a
`--recover`. Nothing else runs, staging idioms included. A compound
command that smuggles other work next to a legitimate runner call
(`cat docs/x; ... codex-run.sh ...`) is denied — whole-string matching was the
v3.3-review bypass. Denied calls get a re-instruction BEFORE running — the
2026-07-07 incident burned ~45k wrapper tokens per leg on self-execution.
Denials are measurable: one line in codex-gate.log plus a violation-averted
line in ~/.codex-worker/usage.log. Fail-open on errors — never break other
agents.
"""
import json, re, shlex, sys, time, os

sys.path.insert(0, os.path.dirname(__file__))
from codex_worker_gate_common import (  # noqa: E402
    runner_seg_ok,
    shell_segments,
    strip_heredocs,
)

# The runner path (RUNNER_CALL in codex_worker_gate_common.py, applied via
# runner_seg_ok) must never allow a form the stop-gate refuses to count as proof.
# It MUST include the `.claude/agents/bin/` prefix under the real $HOME: a bare
# `/codex-run.sh` tail let a forwarder write and then exec its own runner (the
# v3.5 write-then-exec bypass), and an unanchored home let a repo-local fake
# runner pass (mirror-gate review 2026-07-14). runner_seg_ok() also demands the
# path be the segment's COMMAND WORD and rejects command/process substitution
# and redirection — as an ARGUMENT it merely rode along while a substitution
# did the real work.
# The request variable is pinned to the literal contract name REQ, not any
# identifier. `read PATH <<'EOF' ... EOF; printf '%s' "$PATH" | runner` would
# read attacker-controlled heredoc text INTO the exported PATH the runner child
# inherits — a planted `/tmp/evil:/usr/bin` body then makes the runner exec a
# forged `codex` (arbitrary code execution with an authentic footer). Only REQ
# is a safe sink; the contract (codex-worker.md) uses exactly REQ. (security
# review round 5, 2026-07-14, high.)
# The IFS= prefix is REQUIRED, not optional: without it `read` strips leading
# IFS whitespace, so a request opening with a blank-line boundary has that
# boundary eaten and its first task line PROMOTED into the privileged
# directive block (SANDBOX:/CWD:/NETWORK: injection — security review round 8,
# 2026-07-14, high). A stale forwarder using the un-prefixed recipe fails
# closed into the re-instruction naming the exact new shape.
REQUEST_ASSIGN = re.compile(
    r"^IFS=\s+read\s+-r\s+-d\s+''\s+(?P<var>REQ)\s+"
    r"<<\s*'(?P<delimiter>\w+)'$"
)
REQUEST_PRINTF = re.compile(
    r'''^printf\s+'%s'\s+"\$(?:\{(?P<braced>REQ)\}|(?P<plain>REQ))"$'''
)
GATE_LOG = os.path.expanduser('~/.claude/hooks/codex-gate.log')
USAGE_LOG = os.path.expanduser('~/.codex-worker/usage.log')

# The two runner-authored continuations a forwarder may run after a launch.
# This PreToolUse hook sees ONE Bash command, never the transcript, so it can
# only validate these SYNTACTICALLY — the argument's provenance is bound by the
# other two layers, by design (mirror-gate round 5): the runner's --poll REFUSES
# a scratch without its own launch-proof stamp (a forged /tmp/codex-worker.* dir
# fails at the runner, not merely here), and the stop-gate REFUSES to accept a
# --recover whose session id was not emitted by a launch/poll/recover result in
# THIS transcript. So a syntactically-valid but injected id can neither poll a
# foreign run nor have its recovered output accepted as a result.
POLL_SCRATCH = re.compile(r'^/tmp/codex-worker\.(?!\S*\.\.)[A-Za-z0-9._-]+$')
RECOVER_ID = re.compile(r'^[0-9a-fA-F-]{8,}$')

REINSTRUCT = (
    'codex-worker bright line: pipe the ENTIRE prompt verbatim with the exact '
    'heredoc-assignment (`IFS= read -r -d \'\' REQ <<\'CODEX_REQ_EOF\'` ... '
    '`CODEX_REQ_EOF` — the IFS= prefix is required) + `printf \'%s\' "$REQ" | '
    '~/.claude/agents/bin/codex-run.sh --footer --parse-request` launch shape. '
    'The runner must be the final pipeline segment and no other flags are allowed. '
    'After launch, run only the runner-authored --poll continuation, or '
    '`~/.claude/agents/bin/codex-run.sh --footer --recover <session-id>` when the '
    'stop hook tells you to recover. Never parse directives, read task files, '
    'inspect the repo, or solve the task yourself; relay runner stdout verbatim. '
    'The v3.9 flag-composed launch (--model/--effort/--sandbox/--cwd/--network) '
    'is REMOVED: if that is the shape your instructions describe, they are stale '
    '— use the --parse-request shape above.'
)


def log(path, line):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'a') as f:
            f.write(line + '\n')
    except OSError:
        pass


def _runner_argv(segment):
    if not runner_seg_ok(segment):
        return None
    try:
        return shlex.split(segment)
    except ValueError:
        return None


def _parse_request_shape(cmd):
    """Accept only the v4 heredoc assignment + final runner pipeline."""
    normalized = strip_heredocs(cmd or '')
    lines = normalized.splitlines()
    if len(lines) != 2:
        return False
    assigned = REQUEST_ASSIGN.fullmatch(lines[0].strip())
    if not assigned:
        return False
    # The contract permits exactly CODEX_REQ_EOF and its collision extensions
    # (CODEX_REQ_EOF_1, ...) — an arbitrary delimiter is an off-contract
    # forwarder improvisation (re-review 2026-07-14; tightening only).
    if not re.fullmatch(r'CODEX_REQ_EOF(?:_\d+)?', assigned.group('delimiter')):
        return False
    pipeline = lines[1].split('|')
    if len(pipeline) != 2:
        return False
    producer, runner = (part.strip() for part in pipeline)
    printed = REQUEST_PRINTF.fullmatch(producer)
    if not printed:
        return False
    printed_var = printed.group('braced') or printed.group('plain')
    argv = _runner_argv(runner)
    return printed_var == assigned.group('var') and bool(
        argv and argv[1:] == ['--footer', '--parse-request']
    )


def _continuation_shape(cmd):
    """Accept only a lone runner-authored --poll or --recover continuation.

    v4.0.2 (mirror-gate review 2026-07-14, high): the v3.9 transition lane is
    GONE. It let a forwarder heredoc-stage task text of its own authorship and
    launch it with `--sandbox workspace-write --network on --cwd / --output-file
    <path>` — prompt-injected text could therefore replace the orchestrator's
    request, write outside the workspace, and still return an authentic footer
    that binds as proof. No flag vocabulary can be narrow enough while the
    forwarder still chooses both the task text and the runner's powers; only
    `--parse-request` binds the launch to the prompt the forwarder was handed.
    A stale v3.9-cached forwarder now fails CLOSED and loudly (deny + REINSTRUCT
    naming the v4 shape) instead of launching an unbound request.
    """
    normalized = strip_heredocs(cmd or '')
    segments = [seg for seg in shell_segments(normalized) if seg]
    if len(segments) != 1 or not runner_seg_ok(segments[0]):
        return False
    argv = _runner_argv(segments[0])
    if not argv or len(argv) != 4 or argv[1] != '--footer':
        return False
    if argv[2] == '--poll':
        return bool(POLL_SCRATCH.fullmatch(argv[3]))
    if argv[2] == '--recover':
        return bool(RECOVER_ID.fullmatch(argv[3]))
    return False


def allowed(cmd):
    # --request-file is DELIBERATELY not accepted here. This hook fires only for
    # codex-worker forwarders (main(): agent_type == 'codex-worker'); the direct
    # dispatch lane is the ORCHESTRATOR running the runner from its own Bash,
    # which this hook never sees. Allowing it would hand a forwarder the one
    # power v4 exists to remove: it could heredoc-write its own request file
    # (the legacy /tmp staging shapes still permit that) with directives of its
    # choosing — SANDBOX: workspace-write, NETWORK: on, CWD: / — or a different
    # task entirely, then relay a genuine footer that binds as proof for work
    # the orchestrator never asked for. The forwarder may only forward the
    # prompt it was given, so --parse-request is its sole launch shape.
    if _parse_request_shape(cmd):
        return True
    return _continuation_shape(cmd)


def main():
    try:
        j = json.load(sys.stdin)
    except Exception:
        return
    if j.get('agent_type') != 'codex-worker' or j.get('tool_name') != 'Bash':
        return
    cmd = (j.get('tool_input') or {}).get('command') or ''
    ts = time.strftime('%Y-%m-%dT%H:%M:%S')
    head = cmd.splitlines()[0][:120] if cmd else '(empty)'
    if allowed(cmd):
        log(GATE_LOG, f'{ts} pre-allow {head}')
        return
    log(GATE_LOG, f'{ts} pre-deny {head}')
    log(USAGE_LOG, f'{ts} violation-averted agent={j.get("agent_id", "?")} cwd={j.get("cwd", "?")}')
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': REINSTRUCT,
    }}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        pass
