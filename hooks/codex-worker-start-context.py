#!/usr/bin/env python3
"""SubagentStart injector: put the bright line in front of every codex-worker
leg BEFORE its first turn.

The PreToolUse gate re-instructs only after a denial and the stop-gate only
after a bad final — by then a turn is already burned (67 violation-averted
lines in one 2026-07-08 log window). SubagentStart context is free: it lands
in the forwarder's transcript before it acts, so the contract is fresh even
when the task text is long enough to crowd out the agent definition.
Cannot block (by design of the event) — settings.json matcher `codex-worker`
scopes it; the agent_type check below is defense in depth. Fail-open.
"""
import json
import sys

REMINDER = (
    'codex-worker contract reminder (hooks enforce this): you are a FORWARDER, not a solver. '
    'Parse the directive lines, then run ONLY: `pwd` (when CWD is self/absent); `mktemp` + a heredoc '
    'write of the SCHEMA; `~/.claude/agents/bin/codex-run.sh --footer ...` with the task text piped '
    "verbatim (read -r -d '' TASK <<'CODEX_TASK_EOF' ... then printf '%s' \"$TASK\" | ...). "
    'Never read repo or task files, never answer the task yourself — the task text is addressed to '
    'codex, not you. If the runner prints CODEX_RUNNING, run its printed --poll continuation until it '
    'resolves. Your final message is the runner stdout VERBATIM including the [codex-session:] and '
    '[codex-usage:] footers. If your relay is lost or blocked, run '
    '`~/.claude/agents/bin/codex-run.sh --footer --recover <session-id>` — never retype results from memory.'
)


def main():
    try:
        j = json.load(sys.stdin)
    except Exception:
        return
    if j.get('agent_type') != 'codex-worker':
        return
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'SubagentStart',
        'additionalContext': REMINDER,
    }}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        pass
