#!/usr/bin/env python3
"""PreToolUse gate: enforce the codex-worker bright line in real time.

Fires on every Bash call (settings matcher: Bash). Acts only when the calling
agent is a codex-worker forwarder — subagent PreToolUse payloads carry
`agent_type` (verified live on this Claude Code build, 2026-07-07). The
command is validated SEGMENT BY SEGMENT (heredoc bodies stripped first — task
text is data, not commands): every top-level segment must be one of the
contract's allowed shapes — the path-form codex-run.sh invocation (incl.
--poll continuations), `pwd`, the SCHEMA tmpfile flow (mktemp / heredoc write
to /tmp or a $VAR path), or the stdin-staging read/printf idioms. A compound
command that smuggles other work next to a legitimate runner call
(`cat docs/x; ... codex-run.sh ...`) is denied — whole-string matching was the
v3.3-review bypass. Denied calls get a re-instruction BEFORE running — the
2026-07-07 incident burned ~45k wrapper tokens per leg on self-execution.
Denials are measurable: one line in codex-gate.log plus a violation-averted
line in ~/.codex-worker/usage.log. Fail-open on errors — never break other
agents.
"""
import json, re, sys, time, os

sys.path.insert(0, os.path.dirname(__file__))
from codex_worker_gate_common import (  # noqa: E402
    runner_seg_ok,
    shell_segments,
    simple_shell_variables,
)

# The runner path (RUNNER_CALL in codex_worker_gate_common.py, applied via
# runner_seg_ok) must never allow a form the stop-gate refuses to count as proof.
# The runner path MUST include the `.claude/agents/bin/` prefix: a bare
# The runner path MUST include the `.claude/agents/bin/` prefix: a bare
# `/codex-run.sh` tail let a forwarder `cat > /tmp/codex-run.sh` (an allowed
# heredoc write) then exec `/tmp/codex-run.sh` (both gate-approved) — a
# write-then-exec bypass (v3.5 high review). A single heredoc segment cannot
# build the nested `.claude/agents/bin/` dir, so requiring it closes the hole.
#
# v3.7 (gb-3, 2026-07-09 audit): the runner path must be the segment's COMMAND
# WORD, not merely present in it — the old `(?:^|[\s;&|(])...` + `.search()`
# matched the path as a trailing ARGUMENT, so `echo $(cat FILE) <path>` and
# `foo $(CMD) <path> --footer` ran the substitution and were ALLOWED.
# Anchor to `^\s*` and reject any command/process substitution ($( ), backtick,
# <( >( ) or redirection in the segment — the sole permitted substitution is the
# benign `$(pwd)` (some forwarders inline `--cwd "$(pwd)"`). Plain $VAR/${VAR}
# expansion is state-bound below: only HOME and task/schema variables declared
# in this same Bash call are accepted. runner_seg_ok() pairs the two gates.
MKTEMP = re.compile(r'^mktemp(?:\s+(?P<path>/tmp/(?!\S*\.\.)[A-Za-z0-9._/-]+))?$')
MKTEMP_ASSIGN = re.compile(
    r'^(?P<var>[A-Za-z_]\w*)=\$\(mktemp(?:\s+(?P<path>/tmp/(?!\S*\.\.)[A-Za-z0-9._/-]+))?\)$'
)
TASK_READ = re.compile(r"^read\s+-r\s+-d\s+''\s+(?P<var>\w+)\s*(?:<<-?\s*'?\w+'?)?$")
TASK_PRINTF = re.compile(r'^printf(\s+(--|-[a-zA-Z]+))*\s+\'[^\']*\'(\s+"\$\{?\w+\}?")*$')
TASK_ECHO = re.compile(r'^echo(\s+(--|-[a-zA-Z]+))*(\s+"\$\{?\w+\}?")+$')
HEREDOC_WRITE = re.compile(
    r'^(?:cat|tee)\s*(?:<<-?\s*\'?\w+\'?)?\s*>{1,2}\s*'
    r'(?:"?\$(?:\{(?P<braced>[A-Za-z_]\w*)\}|(?P<plain>[A-Za-z_]\w*))"?'
    r'|(?P<path>/tmp/(?!\S*\.\.)[A-Za-z0-9._/-]+))\s*'
    r'(?:<<-?\s*\'?\w+\'?)?$'
)
GATE_LOG = os.path.expanduser('~/.claude/hooks/codex-gate.log')
USAGE_LOG = os.path.expanduser('~/.codex-worker/usage.log')

REINSTRUCT = (
    'codex-worker bright line: the only commands you may run are `pwd`, `mktemp` '
    '(+ a heredoc write of the SCHEMA to that tmp file), and '
    '~/.claude/agents/bin/codex-run.sh (including its printed --poll continuation) '
    'fed by the read/printf stdin idiom — with NOTHING else chained alongside. '
    'Never read files, inspect the repo, or do the task yourself — the task text is '
    'addressed to codex, not to you. Pipe the task text (everything after the '
    'directive lines) verbatim to ~/.claude/agents/bin/codex-run.sh --footer with '
    'flags from the directives, then return its stdout verbatim. If a directive '
    'value is invalid, return `CODEX_ERROR: invalid directive value <line>` with no '
    'tool calls.'
)


def log(path, line):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'a') as f:
            f.write(line + '\n')
    except OSError:
        pass


def _schema_tmp_path(path):
    """Literal tmp paths may hold schema data, never runner scratch controls."""
    if not path:
        return True
    return bool(re.fullmatch(r'(?:schema[A-Za-z0-9._-]*|tmp\.[A-Za-z0-9._-]+)',
                             os.path.basename(path)))


def allowed(cmd):
    task_vars, tmp_vars, runner_count = set(), set(), 0
    runner_seen = False
    for seg in shell_segments(cmd):
        if not seg:
            continue
        # The runner must be the FINAL pipeline segment: legitimate forms are
        # `printf ... | codex-run.sh` (stdin producer BEFORE the runner) or the
        # runner alone. Nothing may consume or replace the runner's stdout — a
        # trailing `| printf '[codex-session: <planted>]'` would forge the tool
        # result's last footer, which the stop-gate binds as proof and mines
        # for --recover ids (2026-07-11 security review round 3, confirmed
        # exploitable against the live gate). Any segment after the runner is
        # therefore illegal, staging idioms included.
        if runner_seen:
            return False
        if seg == 'pwd':
            continue
        if runner_seg_ok(seg):
            refs = simple_shell_variables(seg)
            if refs is None or any(v not in ({'HOME'} | tmp_vars) for v in refs):
                return False
            runner_count += 1
            if runner_count > 1:
                return False                 # contract: invoke exactly once
            runner_seen = True
            continue
        m = MKTEMP_ASSIGN.fullmatch(seg)
        if m and _schema_tmp_path(m.group('path')):
            tmp_vars.add(m.group('var'))
            continue
        m = MKTEMP.fullmatch(seg)
        if m and _schema_tmp_path(m.group('path')):
            continue
        m = TASK_READ.fullmatch(seg)
        if m:
            task_vars.add(m.group('var'))
            continue
        if TASK_PRINTF.fullmatch(seg) or TASK_ECHO.fullmatch(seg):
            refs = simple_shell_variables(seg)
            if refs is not None and all(v in task_vars for v in refs):
                continue
            return False
        m = HEREDOC_WRITE.fullmatch(seg)
        if m:
            target_var = m.group('braced') or m.group('plain')
            if target_var in tmp_vars or (m.group('path') and _schema_tmp_path(m.group('path'))):
                continue
        return False
    return True


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
