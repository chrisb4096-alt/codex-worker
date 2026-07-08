#!/usr/bin/env python3
"""SubagentStop gate: a codex-worker leg may not finish without proof of forwarding.

Fires on every subagent stop. Self-filters: only acts when the subagent's first
user message opens with codex-worker directive lines (EFFORT:/SANDBOX:/...).
Proof must be in the FINAL message, not merely somewhere in the transcript: a
`[codex-session:]` footer (or a StructuredOutput submission after a real
path-form codex-run.sh invocation), or a loud leading CODEX_ERROR. A runner
call alone is NOT proof — a forwarder that launched the detached run, never
polled, and returned "waiting for the review to complete..." passed the old
check (2026-07-08 placeholder incident); it now gets blocked once with a
poll-and-recover instruction, as does a final message abandoned at
CODEX_RUNNING. Self-execution without any runner call blocks with the
forwarding re-instruction (2026-07-07 incident: 16/16 Workflow forwarders
answered tasks themselves). Second stops always pass (no infinite loops) but
an unproven second stop logs a violation line so misfires stay measurable.
One line per decision appended to codex-gate.log.
"""
import json, re, sys, time, os

DIRECTIVE = re.compile(r'^(EFFORT|SANDBOX|CWD|NETWORK|MCP|MODEL|RESUME|LONG|SCHEMA|REVIEW|OUTPUT_FILE):')
# Footer proof in the final message — the runner prints `missing` when it
# couldn't extract a session id, which is a misfire, not proof. Anchored to
# line start (like every parseCodex caller) so prose QUOTING a footer never
# counts.
SESSION_FOOTER = re.compile(r'^\[codex-session: (?!missing)\S+\]', re.M)
# Path-form invocation of the runner (also matches the printed --poll continuation);
# an `echo codex-run.sh` or a mention inside other text does not count.
# Keep in sync with RUNNER_CALL in executable_codex-worker-bright-line.py —
# the PreToolUse gate must never allow a form this gate refuses to count.
RUNNER_CALL = re.compile(r'(?:^|[\s;&|(])(?:~|/|\$HOME)\S*/codex-run\.sh(?:\s|$)', re.M)
LOG = os.path.expanduser('~/.claude/hooks/codex-gate.log')
USAGE_LOG = os.path.expanduser('~/.codex-worker/usage.log')

def log(verdict, why):
    try:
        with open(LOG, 'a') as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {verdict} {why}\n")
    except OSError:
        pass

def log_violation(j):
    # Never-launched legs leave no usage.log entry, so misfire rates were
    # unmeasurable (2026-07-07 incident fix #4): record the violation.
    try:
        os.makedirs(os.path.dirname(USAGE_LOG), exist_ok=True)
        with open(USAGE_LOG, 'a') as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} violation "
                    f"agent={j.get('agent_id', '?')} cwd={j.get('cwd', '?')}\n")
    except OSError:
        pass

def texts(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(c.get('text', '') for c in content if isinstance(c, dict) and c.get('type') == 'text')
    return ''

def main():
    try:
        j = json.load(sys.stdin)
    except Exception:
        return
    agent_type = j.get('agent_type')
    if agent_type is not None and agent_type != 'codex-worker':
        return                              # authoritative filter when the field exists
    tp = j.get('agent_transcript_path') or j.get('transcript_path')
    if not tp or not os.path.isfile(tp):
        return
    first_user, last_assistant, forwarded, structured = None, '', False, False
    try:
        with open(tp) as f:
            for line in f:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                m = o.get('message') or {}
                role, content = m.get('role'), m.get('content')
                if role == 'user' and first_user is None:
                    first_user = texts(content)
                elif role == 'assistant':
                    t = texts(content)
                    msg_structured = False
                    if isinstance(content, list):
                        for c in content:
                            if not (isinstance(c, dict) and c.get('type') == 'tool_use'):
                                continue
                            if RUNNER_CALL.search((c.get('input') or {}).get('command', '')):
                                forwarded = True
                            elif c.get('name') == 'StructuredOutput':
                                msg_structured = True
                    # StructuredOutput counts as proof only when it is part of the
                    # FINAL message — a stale submission from an earlier rejected
                    # attempt must not vouch for a later placeholder final.
                    if t.strip() or msg_structured:
                        last_assistant = t
                        structured = msg_structured
    except OSError:
        return
    if agent_type is None and (first_user is None or not DIRECTIVE.match(first_user.lstrip())):
        return                              # fallback heuristic when agent_type is absent
    last_assistant = j.get('last_assistant_message') or last_assistant
    head = last_assistant.lstrip()
    # Proof lives in the FINAL message: relayed footers (or a StructuredOutput
    # submission on schema legs — counted only after a real runner call, else
    # it is the self-execution incident wearing a tool call), or a loud
    # CODEX_ERROR. A runner call alone is NOT proof (placeholder incident).
    if head.startswith('CODEX_ERROR'):
        log('allow', 'loud-failure')
        return
    if forwarded and (SESSION_FOOTER.search(last_assistant) or structured):
        log('allow', 'forwarded+proof')
        return
    if j.get('stop_hook_active'):           # already blocked once — never loop, but keep misfires measurable
        log('allow', 'stop_hook_active-unproven')
        log_violation(j)
        return
    log_violation(j)
    if forwarded:
        # Runner was invoked but the final message carries no result: an
        # abandoned CODEX_RUNNING, a "waiting for the review..." placeholder,
        # or a stripped relay. The result may already be on disk — recover it.
        log('block', 'forwarded but final message lacks session footer')
        print(json.dumps({
            'decision': 'block',
            'reason': ('codex-worker contract violation: you invoked codex-run.sh but your final message has no '
                       '[codex-session:] footer — never return placeholder text like "the task is still running". '
                       'If the runner printed CODEX_RUNNING, run its printed --poll continuation command now and '
                       'repeat until it resolves (the detached run survives between your tool calls). Then return '
                       'that stdout VERBATIM including the [codex-session:]/[codex-usage:] footers, or the '
                       'CODEX_ERROR line if it failed.'),
        }))
        return
    log('block', 'no codex invocation in transcript')
    print(json.dumps({
        'decision': 'block',
        'reason': ('codex-worker contract violation: you answered the task yourself instead of forwarding. '
                   'Pipe the task text (everything after the directive lines) verbatim to '
                   '~/.claude/agents/bin/codex-run.sh --footer with flags from the directives '
                   '(--effort/--sandbox/--cwd/...; see ~/.claude/agents/codex-worker.md), then return its stdout '
                   'verbatim including the [codex-session:]/[codex-usage:] footers. If a directive value is '
                   'invalid, return CODEX_ERROR: invalid directive value <line> instead.'),
    }))

if __name__ == '__main__':
    main()
