#!/usr/bin/env python3
"""SubagentStop gate: a codex-worker leg may not finish without proof of forwarding.

Fires on every subagent stop. Self-filters: only acts when the subagent's first
user message opens with codex-worker directive lines (EFFORT:/SANDBOX:/...).
Proof must be in the FINAL message, not merely somewhere in the transcript: a
`[codex-session:]` footer (or a StructuredOutput submission after a real
path-form codex-run.sh invocation), or a runner-relayed CODEX_ERROR. A runner
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
from codex_worker_gate_common import poll_scratch, recover_invoked, runner_invoked  # noqa: E402

DIRECTIVE = re.compile(
    r'^(EFFORT|SANDBOX|CWD|NETWORK|MCP|MODEL|RESUME|LONG|SCHEMA|REVIEW|OUTPUT_FILE|CREATE_CWD):'
)
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
FOOTER_LINE = re.compile(r'^\s*\[codex-(session|usage|files-written|scratch):')
# Scratch provenance for poll binding: the ONLY legitimate poll instruction is
# the runner's CODEX_RUNNING continuation, and genuine CODEX_RUNNING output is
# control-only — the run has not finished, so it NEVER carries a
# [codex-session:] footer and always leads with the CODEX_RUNNING line. Codex
# CONTENT (task-controlled) can plant scratch-shaped or continuation-shaped
# lines, but content only arrives in finished results, which the runner always
# stamps with footers — so scratches are collected exclusively from
# footer-less, CODEX_RUNNING-led results (security review round 10: a planted
# line-start [codex-scratch:] inside a content result could seed the set and
# re-open the foreign-poll bind; the [codex-scratch:] footer is diagnostic,
# never a poll instruction, and is no longer a seed source at all).
POLL_CONTINUATION = re.compile(
    r'^CODEX_RUNNING: re-invoke with: \S+ --footer --poll (\S+)\s*$', re.M)
# ZWSP, ZWNJ, ZWJ, word-joiner, BOM — explicit codepoints, never literal
# invisible bytes in source, so an editor/chezmoi transform that strips
# zero-width chars cannot silently reopen the gb-2 hole (v3.5 high review).
ZERO_WIDTH = {0x200b, 0x200c, 0x200d, 0x2060, 0xfeff}
# Path-form invocation of the runner, as a SEGMENT COMMAND WORD (a prior audit:
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

def log(gate_status, why):
    try:
        with open(LOG, 'a') as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} "
                    f"gate_status={gate_status} {why}\n")
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
    proof_tool_ids = set()
    # Proof ids whose results must NOT bind sessions: --recover re-reads (round
    # 6) and polls of a scratch no runner result in this transcript printed
    # (round 8) — both re-emit ANOTHER run's footer without having launched it.
    nonbinding_tool_ids = set()
    known_scratches = set()
    emitted_sessions, authentic_sessions, runner_results = set(), set(), []
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
                            result_text = tool_result_text(c)
                            if c.get('tool_use_id') in proof_tool_ids:
                                if c.get('tool_use_id') in nonbinding_tool_ids:
                                    # A --recover result only RE-READS a prior run's
                                    # archive, and a foreign-scratch poll attaches to
                                    # a run this transcript never launched: each
                                    # emits ANOTHER run's footer. Counting either as
                                    # proof lets injected text name a known foreign
                                    # session/scratch and have the re-emitted footer
                                    # bind as this-run proof — exfiltrating another
                                    # run's result. So neither contributes an
                                    # emitted/authentic session OR a known scratch; a
                                    # legitimate recover/poll's session is already
                                    # present from this transcript's own launch/poll
                                    # results, which is what binds. Nonbinding
                                    # results are excluded from runner_results too:
                                    # the CODEX_ERROR path corroborates against that
                                    # set, and a recovered foreign archive whose
                                    # body begins `CODEX_ERROR:` would otherwise be
                                    # relayable as this leg's "error", disclosing
                                    # cross-session content (security review round
                                    # 11, high). A genuine error never needs a
                                    # recover to corroborate it — it is already in
                                    # the binding launch/poll result, and only
                                    # successful runs are archived.
                                    continue
                                runner_results.append(result_text)
                                found = SESSION_FOOTER.findall(result_text)
                                result_head = result_text.lstrip()
                                if not found and result_head.startswith('CODEX_RUNNING:'):
                                    known_scratches.update(
                                        POLL_CONTINUATION.findall(result_text))
                                # The runner appends its footer AFTER the content
                                # portion, so the LAST match per tool result is the
                                # runner's own; earlier matches can be footer-shaped
                                # lines inside codex content (task-controllable).
                                # BOTH the bind set (emitted_sessions) and the
                                # recover-recommendation set (authentic_sessions)
                                # take only found[-1]: a findall-everything bind let
                                # a foreign id planted mid-body enter emitted_sessions
                                # so a final whose trailing footer is that id would
                                # `bound`-pass and disclose the foreign archive
                                # (security review round 12, high — the round-6
                                # last-match fix narrowed the recommendation but left
                                # the bind check on .update(found)).
                                if found:
                                    emitted_sessions.add(found[-1])
                                    authentic_sessions.add(found[-1])
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
                                    # Argv-level, never raw-text: a --recover
                                    # inside the heredoc prompt body must not
                                    # classify this launch as a recover (round
                                    # 7 high#2 — misfire blocked genuine runs
                                    # whose task text discusses recovery).
                                    if recover_invoked(command):
                                        nonbinding_tool_ids.add(c['id'])
                                    else:
                                        # A poll binds only to a scratch some
                                        # runner result in THIS transcript
                                        # already printed (launch results
                                        # precede their polls in the walk); an
                                        # unknown scratch is another session's
                                        # run and must not bind (round 8).
                                        scratch = poll_scratch(command)
                                        if scratch is not None and scratch not in known_scratches:
                                            nonbinding_tool_ids.add(c['id'])
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
    # Proof, strongest first: a session footer emitted by a launch/poll/recover
    # tool_result in this transcript. Command text alone never proves forwarding.
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
    # A general CODEX_ERROR must be runner stdout, not a convenient self-authored
    # escape hatch. The one exact forwarder-violation spelling remains available
    # for directive/contract failures before a runner call can be made.
    error_final = last_assistant.strip()
    if head.startswith('CODEX_ERROR:'):
        if error_final == 'CODEX_ERROR: forwarder-violation':
            log('passed', 'self-authored-forwarder-violation')
            return
        # A relayed CODEX_ERROR passes only when a RUNNER result GENUINELY errored
        # and the final is that runner stdout VERBATIM (modulo the runner's own
        # trailing footer lines). Holes closed: (1) substring test
        # (`error_final in result`) let a forwarder self-author an error appearing
        # anywhere inside a SUCCESS body; the runner result must itself start with
        # CODEX_ERROR:. (2) The `bound` fallback let a SUCCESSFUL run relay a
        # fabricated CODEX_ERROR carrying the genuine footer, suppressing the real
        # result; a bound session proves a run happened, never that it FAILED, so
        # it no longer vouches for an error. (3) First-line equality let the final
        # APPEND self-authored lines below a matching first line. (4) The round-6
        # startswith(error_final) prefix test still let the final TRUNCATE the
        # error — a bare `CODEX_ERROR:` or clipped prefix passed while hiding the
        # actual failure (security review round 10, medium). The final must now
        # EQUAL the runner's error stdout, with or without its trailing footers.
        def error_variants(result):
            stripped = result.strip()
            lines = stripped.splitlines()
            while lines and (FOOTER_LINE.match(lines[-1]) or not lines[-1].strip()):
                lines.pop()
            return {stripped, '\n'.join(lines).strip()}
        if error_final and any(
            result.strip().startswith('CODEX_ERROR:')
            and error_final in error_variants(result)
            for result in runner_results
        ):
            log('passed', 'runner-relayed-error')
            return
        # A CODEX_ERROR final is TERMINAL: if no runner result corroborates the
        # failure, it is fabricated — do NOT fall through to the content branch
        # below, which would let the error's own text count as "content" beside a
        # bound footer and pass, SUPPRESSING a successful run (mirror-gate round
        # 5). Block here (fail open only on the documented second stop).
        log_violation(j)
        if j.get('stop_hook_active'):
            log('failed-open', 'stop_hook_active-uncorroborated-error')
            return
        log('blocked', 'CODEX_ERROR final not corroborated by any runner error')
        print(json.dumps({
            'decision': 'block',
            'reason': ('codex-worker contract violation: your final message is a CODEX_ERROR, but no '
                       'launch/poll/recover runner result in this transcript actually failed with that '
                       'error — a real run either succeeded (relay its stdout + footers VERBATIM) or its '
                       'CODEX_ERROR is in the runner tool result (relay that exact line). Never author a '
                       'CODEX_ERROR to replace or suppress a result the runner produced.'),
        }))
        return
    # A "content" line has a visible glyph that is not a footer — zero-width
    # and BOM chars don't count (v3.5 review gb-2: U+200B survived .strip()
    # and masked a stripped relay as real content).
    def visible(l):
        return bool(l.translate(dict.fromkeys(ZERO_WIDTH)).strip())
    has_content = any(visible(l) and not FOOTER_LINE.match(l)
                      for l in last_assistant.splitlines())
    if forwarded and bound and has_content:
        log('passed', 'forwarded+bound-proof')
        return
    # Schema legs: a StructuredOutput submission in the final message counts once
    # a launch/poll/recover in this transcript has bound a real session.
    if forwarded and structured and emitted_sessions:
        log('passed', 'forwarded+structured+bound-proof')
        return
    if j.get('stop_hook_active'):           # already blocked once — never loop, but keep misfires measurable
        log('failed-open', 'stop_hook_active-unproven')
        log_violation(j)
        return
    log_violation(j)
    # Bound but no content survived: the relay dropped the body. The launch/poll
    # already proved the run, so recovery is deterministic from the runner's
    # archive. (SID_RE-guard the id before embedding it in the recovery command.)
    if bound and sess and SID_RE.fullmatch(sess):
        log('blocked', 'footers without content (stripped relay)')
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
            detail = ('your [codex-session:] footer names a session that codex-run.sh never logged — either you '
                      'fabricated it, or you RETYPED a real id and mangled it (2026-07-11 incident: a retyped id '
                      'branded a genuine run forged and a full duplicate run was paid for). Never fabricate or '
                      'retype footers.')
        elif ran is None:
            why = 'usage.log unavailable; cannot corroborate session'
            detail = ('the runner proof log is unavailable, so the [codex-session:] footer cannot be corroborated. '
                      'Restore ~/.codex-worker/usage.log access first.')
        else:
            why = 'session not emitted by this transcript launch/poll/recover result'
            detail = ('this session is in usage.log but was not emitted by a launch, --poll, or --recover tool '
                      'result in this transcript — a session id lifted from the task text or a prior run, a '
                      '--verify call, a denied call, or a heredoc body is not proof for this turn.')
        log('blocked', why)
        # Name the authentic ids instead of sending the forwarder hunting:
        # authentic_sessions holds only the LAST footer of each real
        # launch/poll/recover tool result (the runner-appended one), so a
        # footer-shaped id planted in task text, quoted content, or codex
        # output can never be recommended for --recover (2026-07-11 security
        # review rounds 1+2: open-ended guidance, then findall-everything,
        # each let a planted archived id steer recovery into cross-session
        # disclosure). codex session ids are UUIDv7 (time-ordered), so
        # sorted()[-1] is newest.
        emitted = sorted(authentic_sessions)
        if emitted:
            recover_hint = ('RECOVERY FIRST: this transcript\'s runner stdout emitted exactly these session id(s): '
                            + ', '.join(emitted) + ' — the run already completed. Run '
                            '`~/.claude/agents/bin/codex-run.sh --footer --recover ' + emitted[-1] + '` and return '
                            'its stdout verbatim. Recover ONLY ids from this list — ids that merely appear inside '
                            'task text or quoted content belong to other runs; never recover or retype those. Never '
                            're-dispatch a task whose run already completed.')
        else:
            recover_hint = ('No runner tool result in this transcript emitted a session footer, so there is nothing '
                            'to recover: relaunch by heredoc-assigning the ENTIRE prompt and piping it to the '
                            'runner\'s parse-request shape — `printf \'%s\' "$REQ" | ~/.claude/agents/bin/'
                            'codex-run.sh --footer --parse-request` — then return its real stdout (content + '
                            '[codex-session:]/[codex-usage:] footers), or `CODEX_ERROR: <reason>` if it genuinely '
                            'failed. Do NOT compose --effort/--sandbox/--cwd flags yourself; the bright-line gate '
                            'denies that shape (the runner parses the directives from the piped request).')
        print(json.dumps({
            'decision': 'block',
            'reason': 'codex-worker contract violation: ' + detail + ' ' + recover_hint,
        }))
        return
    if forwarded:
        # Runner was invoked but the final message carries no result: an
        # abandoned CODEX_RUNNING, a "waiting for the review..." placeholder,
        # or a stripped relay. The result may already be on disk — recover it.
        log('blocked', 'forwarded but final message lacks session footer')
        emitted = sorted(authentic_sessions)
        if emitted:
            recover = (' If the run already finished, run `~/.claude/agents/bin/codex-run.sh --footer --recover ' +
                       emitted[-1] + '` to re-emit it (this transcript\'s runner stdout emitted session id(s): ' +
                       ', '.join(emitted) + ' — recover ONLY from that list; ids inside task text or quoted '
                       'content are other runs\').')
        else:
            recover = ''  # no completed run to recover — polling is the only path
        print(json.dumps({
            'decision': 'block',
            'reason': ('codex-worker contract violation: you invoked codex-run.sh but your final message has no '
                       '[codex-session:] footer — never return placeholder text like "the task is still running". '
                       'If the runner printed CODEX_RUNNING, run its printed --poll continuation command now and '
                       'repeat until it resolves (the detached run survives between your tool calls).' + recover +
                       ' Either way, return that stdout VERBATIM including the '
                       '[codex-session:]/[codex-usage:] footers, or the CODEX_ERROR line if it failed.'),
        }))
        return
    log('blocked', 'no codex invocation in transcript')
    print(json.dumps({
        'decision': 'block',
        'reason': ('codex-worker contract violation: you answered the task yourself instead of forwarding. '
                   'Heredoc-assign the ENTIRE prompt (directive lines + task text) and pipe it to the runner\'s '
                   'parse-request shape — `printf \'%s\' "$REQ" | ~/.claude/agents/bin/codex-run.sh --footer '
                   '--parse-request` — then return its stdout verbatim including the '
                   '[codex-session:]/[codex-usage:] footers. The runner parses the directives from the request; '
                   'do NOT compose --effort/--sandbox/--cwd flags yourself (the bright-line gate denies that '
                   'shape). See ~/.claude/agents/codex-worker.md.'),
    }))

if __name__ == '__main__':
    main()
