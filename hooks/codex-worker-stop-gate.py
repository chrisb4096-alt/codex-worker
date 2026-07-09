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
answered tasks themselves). A footers-only final (body stripped by the relay,
2026-07-08 incident: 4 legs) blocks once with the exact
`codex-run.sh --footer --recover <session>` command. Second stops always pass
(no infinite loops) but an unproven second stop logs a violation line so
misfires stay measurable. One line per decision appended to codex-gate.log.
"""
import json, re, sys, time, os

sys.path.insert(0, os.path.dirname(__file__))
from codex_worker_gate_common import runner_invoked  # noqa: E402

DIRECTIVE = re.compile(r'^(EFFORT|SANDBOX|CWD|NETWORK|MCP|MODEL|RESUME|LONG|SCHEMA|REVIEW|OUTPUT_FILE):')
# Footer proof in the final message — the runner prints `missing` when it
# couldn't extract a session id, which is a misfire, not proof. Anchored to
# line start (like every parseCodex caller) so prose QUOTING a footer never
# counts. Captures the id so block reasons can hand back the exact
# `--recover <id>` command.
SESSION_FOOTER = re.compile(r'^\[codex-session: (?!missing)(\S+)\]', re.M)
# Telemetry footers are NOT content: a final message that is footers-only
# means the relay dropped the body (2026-07-08: 4 legs ran ok, returned
# stripped finals twice, content stranded in the archive). The
# [codex-final-file:] envelope IS content — deliberately not in this set.
FOOTER_LINE = re.compile(r'^\s*\[codex-(session|usage|files-written):')
# ZWSP, ZWNJ, ZWJ, word-joiner, BOM — explicit codepoints, never literal
# invisible bytes in source, so an editor/chezmoi transform that strips
# zero-width chars cannot silently reopen the gb-2 hole (v3.5 high review).
ZERO_WIDTH = {0x200b, 0x200c, 0x200d, 0x2060, 0xfeff}
# Path-form invocation of the runner, as a SEGMENT COMMAND WORD (v3.7, gb-3:
# `echo <path>` used to set forwarded=True — an unanchored `.search()` counted
# the path as an argument, so self-authored content + `echo <path>` + a forged
# footer passed both gates). Keep in sync with executable_codex-worker-bright-line.py.
LOG = os.path.expanduser('~/.claude/hooks/codex-gate.log')
USAGE_LOG = os.path.expanduser('~/.codex-worker/usage.log')
SID_RE = re.compile(r'[0-9a-fA-F-]{8,}')


def session_ran(sid):
    """UNFORGEABLE proof: only codex-run.sh writes `ok session=<id>` to usage.log,
    before the forwarder's final message exists — so a model cannot fabricate it.
    True = codex genuinely ran; False = usage.log readable but this id is absent
    (forged/self-authored footer); None = usage.log unreadable (fail closed: a
    self-asserted footer is not proof)."""
    if not sid or not SID_RE.fullmatch(sid):
        return False
    # Match the session as an EXACT positional field (`<ts> ok session=<id> ...`),
    # never a substring: `session=<id>` in `if x in line` accepted an 8-hex
    # PREFIX of a real id, and a run whose --cwd embedded `ok session=<forged> `
    # would plant that token later in its own log line (v3.7 review).
    target = 'session=' + sid
    try:
        with open(USAGE_LOG) as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3 and parts[1] == 'ok' and parts[2] == target:
                    return True
        return False
    except OSError:
        return None

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


def tool_result_text(block):
    content = block.get('content', '') if isinstance(block, dict) else ''
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(c.get('text', '') for c in content
                         if isinstance(c, dict) and c.get('type') == 'text')
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
    proof_tool_ids, emitted_sessions = set(), set()
    try:
        with open(tp) as f:
            for line in f:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                m = o.get('message') or {}
                role, content = m.get('role'), m.get('content')
                if role == 'user':
                    if first_user is None:
                        first_user = texts(content)
                    if isinstance(content, list):
                        for c in content:
                            if not (isinstance(c, dict) and c.get('type') == 'tool_result'):
                                continue
                            if c.get('tool_use_id') in proof_tool_ids:
                                emitted_sessions.update(SESSION_FOOTER.findall(tool_result_text(c)))
                elif role == 'assistant':
                    t = texts(content)
                    msg_structured = False
                    if isinstance(content, list):
                        for c in content:
                            if not (isinstance(c, dict) and c.get('type') == 'tool_use'):
                                continue
                            command = (c.get('input') or {}).get('command', '')
                            if runner_invoked(command):
                                forwarded = True
                                if runner_invoked(command, proof_only=True) and c.get('id'):
                                    proof_tool_ids.add(c['id'])
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
    # Proof, strongest first: (1) the session id is in the RUNNER-OWNED
    # usage.log (unforgeable — codex-run.sh writes it before the final exists);
    # (2) the same bound proof plus a StructuredOutput submission for schema
    # legs. Command text alone never proves forwarding: the matching launch or
    # poll tool_result must have emitted the session. A loud CODEX_ERROR is an
    # honest failure.
    if head.startswith('CODEX_ERROR'):
        log('allow', 'loud-failure')
        return
    # The runner appends its [codex-session:] footer AFTER the content, so the
    # AUTHENTIC footer is the LAST match — an earlier footer-shaped line inside
    # relayed content (e.g. codex quoting a footer while reviewing this very repo)
    # must not shadow it (v3.7 high review: first-match branded genuine runs forged).
    sess_ids = SESSION_FOOTER.findall(last_assistant)
    sess = sess_ids[-1] if sess_ids else None
    # `bound` is the primary, unforgeable proof on the Agent lane: the session id
    # appears in a launch/poll/recover tool_result THIS transcript produced, and a
    # tool_result is real runner stdout the model cannot fabricate. usage.log
    # (`ran`) is corroboration for the block MESSAGES only — it must NEVER gate an
    # allow, because the runner's usage.log append is best-effort and can fail
    # (mode 0400 / ENOSPC / race) on a genuine run, which would otherwise brand
    # real work "forged" (v3.7 high review).
    bound = bool(sess and sess in emitted_sessions)
    ran = session_ran(sess)             # corroboration: True=in usage.log, False=absent, None=unreadable
    # A "content" line has a visible glyph that is not a footer — zero-width
    # and BOM chars don't count (v3.5 review gb-2: U+200B survived .strip()
    # and masked a stripped relay as real content).
    def visible(l):
        return bool(l.translate(dict.fromkeys(ZERO_WIDTH)).strip())
    has_content = any(visible(l) and not FOOTER_LINE.match(l)
                      for l in last_assistant.splitlines())
    if forwarded and bound and has_content:
        log('allow', 'forwarded+bound-proof')
        return
    # Schema legs: a StructuredOutput submission in the final message counts once
    # a launch/poll/recover in this transcript has bound a real session.
    if forwarded and structured and emitted_sessions:
        log('allow', 'forwarded+structured+bound-proof')
        return
    if j.get('stop_hook_active'):           # already blocked once — never loop, but keep misfires measurable
        log('allow', 'stop_hook_active-unproven')
        log_violation(j)
        return
    log_violation(j)
    # Bound but no content survived: the relay dropped the body. The launch/poll
    # already proved the run, so recovery is deterministic from the runner's
    # archive. (SID_RE-guard the id before embedding it in the recovery command.)
    if bound and sess and SID_RE.fullmatch(sess):
        log('block', 'footers without content (stripped relay)')
        print(json.dumps({
            'decision': 'block',
            'reason': ('codex-worker contract violation: your final message carries the [codex-session:] footer but '
                       'no content — the relay dropped the body. Recover it mechanically: run '
                       '`~/.claude/agents/bin/codex-run.sh --footer --recover ' + sess + '` and return that '
                       'stdout VERBATIM (content + footers). Never retype the result from memory.'),
        }))
        return
    # A [codex-session:] footer NOT backed by any launch/poll/recover tool_result
    # in this transcript is unproven for this turn — usage.log only sharpens the
    # message (forged id / log unreadable / lifted id), never the verdict.
    if sess:
        if ran is False:
            why = 'forged session footer (not in usage.log)'
            detail = ('your [codex-session:] footer names a session that codex-run.sh never logged — you did NOT '
                      'run codex. Never fabricate footers.')
        elif ran is None:
            why = 'usage.log unavailable; cannot corroborate session'
            detail = ('the runner proof log is unavailable, so the [codex-session:] footer cannot be corroborated. '
                      'Restore ~/.codex-worker/usage.log access first.')
        else:
            why = 'session not emitted by this transcript launch/poll/recover result'
            detail = ('this session is in usage.log but was not emitted by a launch, --poll, or --recover tool '
                      'result in this transcript — a session id lifted from the task text or a prior run, a '
                      '--verify call, a denied call, or a heredoc body is not proof for this turn.')
        log('block', why)
        print(json.dumps({
            'decision': 'block',
            'reason': ('codex-worker contract violation: ' + detail + ' Pipe the task text verbatim to '
                       '~/.claude/agents/bin/codex-run.sh --footer with the directive flags and return its real '
                       'stdout (content + [codex-session:]/[codex-usage:] footers), recover a completed run with '
                       '--recover, or return `CODEX_ERROR: <reason>` if it genuinely failed.'),
        }))
        return
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
                       'repeat until it resolves (the detached run survives between your tool calls). If the runner '
                       'already finished (its stdout with a [codex-session: <id>] footer appeared in an earlier tool '
                       'result), run `~/.claude/agents/bin/codex-run.sh --footer --recover <that session id>` to '
                       're-emit it. Either way, return that stdout VERBATIM including the '
                       '[codex-session:]/[codex-usage:] footers, or the CODEX_ERROR line if it failed.'),
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
