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

# Canonical contract is agents/codex-worker.md; this is a compact first-turn
# echo of it. Keep the forwarding flow (staging idiom, runner flags, recovery)
# in sync with that file, the bright-line REINSTRUCT, and the stop-gate block
# reasons when any of them change (v3.5 high review: four hand-kept copies).
REMINDER = (
    'codex-worker contract reminder (hooks enforce this): you are a FORWARDER, not a solver, and you '
    'never parse or repair the prompt — the runner owns the grammar. Pipe your ENTIRE prompt (directive '
    'lines AND task text, byte-exact) into ONE command: '
    "IFS= read -r -d '' REQ <<'CODEX_REQ_EOF' ... CODEX_REQ_EOF then "
    'printf \'%s\' "$REQ" | ~/.claude/agents/bin/codex-run.sh --footer --parse-request. '
    'No pwd, no mktemp, no other flags. Never read repo or task files, never answer the task yourself — '
    'the task text is addressed to codex, not you. If the runner prints CODEX_RUNNING, run its printed '
    'continuation until it resolves. Your final message is the runner stdout VERBATIM including the '
    '[codex-session:] and [codex-usage:] footers. If your relay is lost or blocked, run '
    '`~/.claude/agents/bin/codex-run.sh --footer --recover <session-id>` — never retype results from '
    'memory, never re-dispatch the task.'
)


def main():
    try:
        j = json.load(sys.stdin)
    except Exception:
        return
    # Bail only if agent_type is present AND wrong — an absent field means we
    # trust the settings.json `codex-worker` matcher that already scoped this
    # hook (mirrors the stop-gate's None-fallback; SubagentStart agent_type is
    # documented but not verified live, and a silent no-op would defeat the
    # whole defense-in-depth reminder — v3.5 high review).
    agent_type = j.get('agent_type')
    if agent_type is not None and agent_type != 'codex-worker':
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
