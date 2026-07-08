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

# Keep in sync with RUNNER_CALL in executable_codex-worker-stop-gate.py —
# PreToolUse must never allow a form the stop-gate refuses to count as proof.
RUNNER_CALL = re.compile(r'(?:^|[\s;&|(])(?:~|/|\$HOME)\S*/codex-run\.sh(?:\s|$)')
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")
SEG_OK = [re.compile(p) for p in (
    r'^$',
    r'^pwd$',
    r'^[A-Za-z_]\w*=\$\(\s*mktemp(\s[^()]*)?\s*\)$',            # SCHEMA_FILE=$(mktemp)
    r'^mktemp(\s\S+)*$',
    r"^read\s+-r\s+-d\s+''\s+\w+\s*(<<-?\s*'?\w+'?)?$",         # task staging
    # pipe feed, no redirects. printf MUST carry a single-quoted format
    # literal — a bare `printf "$TASK"` treats task bytes as the format
    # string and corrupts %-sequences (caught in v3.5 review). echo may be
    # var-only (`echo "$TASK"` — 2026-07-08 false-deny class).
    r'^printf(\s+-[a-zA-Z]+)*\s+\'[^\']*\'(\s+"\$\{?\w+\}?")*$',
    r'^echo(\s+-[a-zA-Z]+)*(\s+\'[^\']*\')?(\s+"\$\{?\w+\}?")*$',
    # heredoc write to a tmpfile — marker before OR after the redirect
    # (`cat <<'EOF' > "$F"` was false-denied 2026-07-07, costing 2 turns).
    # The literal target is a SINGLE /tmp segment of a safe charset — NOT
    # `\S+`, which matched `/tmp/$(...)` command substitution and `/tmp/../`
    # traversal from inside an allowed segment (v3.5 adversarial review gb-1).
    r'^(cat|tee)\s*(<<-?\s*\'?\w+\'?)?\s*>{1,2}\s*("?\$\{?\w+\}?"?|/tmp/[A-Za-z0-9._-]+)\s*(<<-?\s*\'?\w+\'?)?$',
)]
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


def strip_heredocs(cmd):
    """Drop heredoc bodies: task text may contain anything, including text
    that looks like commands or like the runner path — it is data."""
    lines, out, i = cmd.split('\n'), [], 0
    while i < len(lines):
        out.append(lines[i])
        m = HEREDOC.search(lines[i])
        i += 1
        if m:
            delim = m.group(2)
            while i < len(lines) and lines[i].strip() != delim:
                i += 1
            i += 1  # skip the delimiter line
    return '\n'.join(out)


def allowed(cmd):
    s = strip_heredocs(cmd)
    s = re.sub(r'\\\n\s*', ' ', s)          # rejoin backslash continuations
    for seg in re.split(r'[;\n|&]+', s):
        seg = seg.strip()
        if RUNNER_CALL.search(seg):
            continue                         # the one real job (launch or poll)
        if any(p.match(seg) for p in SEG_OK):
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
