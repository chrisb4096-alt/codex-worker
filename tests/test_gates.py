#!/usr/bin/env python3
"""Unit matrix for the three gates. Stdlib only: python3 tests/test_gates.py

Each gate runs as a subprocess with HOME pointed at a tmpdir, exactly as the
Claude Code hook runner invokes it, so log side-effects stay isolated and the
tests exercise the real stdin/stdout contract.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIGHT = os.path.join(REPO, 'hooks', 'codex-worker-bright-line.py')
STOP = os.path.join(REPO, 'hooks', 'codex-worker-stop-gate.py')
ARGS = os.path.join(REPO, 'hooks', 'workflow-args-gate.py')


def run(gate, payload, home):
    p = subprocess.run([sys.executable, gate], input=json.dumps(payload),
                       capture_output=True, text=True, env={**os.environ, 'HOME': home})
    out = p.stdout.strip()
    return json.loads(out) if out else None


def denied(res):
    return bool(res) and (res.get('hookSpecificOutput') or {}).get('permissionDecision') == 'deny'


def blocked(res):
    return bool(res) and res.get('decision') == 'block'


class GateTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()

    def usage_log(self):
        try:
            with open(os.path.join(self.home, '.codex-worker', 'usage.log')) as f:
                return f.read()
        except OSError:
            return ''


class TestArgsGate(GateTest):
    def call(self, tool_input):
        return run(ARGS, {'tool_name': 'Workflow', 'tool_input': tool_input}, self.home)

    def test_object_args_allowed(self):
        self.assertIsNone(self.call({'name': 'codex-review', 'args': {'cwd': '/tmp'}}))

    def test_serialized_object_args_allowed(self):
        # Some harness builds stringify object args before the hook sees them
        # (2026-07-08 false-positive incident) — must NOT deny.
        self.assertIsNone(self.call({'name': 'codex-review', 'args': json.dumps({'cwd': '/tmp'})}))

    def test_double_encoded_args_denied(self):
        double = json.dumps(json.dumps({'cwd': '/tmp'}))
        self.assertTrue(denied(self.call({'name': 'codex-review', 'args': double})))

    def test_unguarded_script_denied(self):
        script = "export const meta = {name:'x',description:'y'}\nreturn args.cwd"
        self.assertTrue(denied(self.call({'script': script})))

    def test_unguarded_destructuring_denied(self):
        # 2026-07-08 review: `const {cwd} = args` slipped past the args.[ detector.
        script = "export const meta = {name:'x',description:'y'}\nconst {cwd} = args\nreturn cwd"
        self.assertTrue(denied(self.call({'script': script})))

    def test_unguarded_optional_chaining_denied(self):
        script = "export const meta = {name:'x',description:'y'}\nreturn args?.cwd"
        self.assertTrue(denied(self.call({'script': script})))

    def test_guarded_script_allowed(self):
        script = ("export const meta = {name:'x',description:'y'}\n"
                  "if (typeof args === 'string') { try { args = JSON.parse(args) } catch {} }\n"
                  "if (!args?.cwd) throw new Error('args.cwd required')\nreturn args.cwd")
        self.assertIsNone(self.call({'script': script}))

    def test_other_tools_ignored(self):
        self.assertIsNone(run(ARGS, {'tool_name': 'Bash', 'tool_input': {'command': 'ls'}}, self.home))

    def test_garbage_stdin_fails_open(self):
        p = subprocess.run([sys.executable, ARGS], input='not json', capture_output=True,
                           text=True, env={**os.environ, 'HOME': self.home})
        self.assertEqual(p.stdout.strip(), '')


class TestBrightLine(GateTest):
    def call(self, command, agent_type='codex-worker'):
        return run(BRIGHT, {'agent_type': agent_type, 'tool_name': 'Bash', 'agent_id': 't',
                            'tool_input': {'command': command}}, self.home)

    def test_runner_pipe_allowed(self):
        cmd = ("read -r -d '' TASK <<'CODEX_TASK_EOF'\ndo the thing\nCODEX_TASK_EOF\n"
               "printf '%s' \"$TASK\" | ~/.claude/agents/bin/codex-run.sh --footer --effort medium")
        self.assertIsNone(self.call(cmd))

    def test_poll_continuation_allowed(self):
        self.assertIsNone(self.call('~/.claude/agents/bin/codex-run.sh --footer --poll /tmp/codex-worker.abc123'))

    def test_pwd_and_mktemp_allowed(self):
        self.assertIsNone(self.call('pwd'))
        self.assertIsNone(self.call('SCHEMA_FILE=$(mktemp)'))

    def test_file_read_denied(self):
        self.assertTrue(denied(self.call('cat src/main.py')))

    def test_compound_smuggle_denied(self):
        self.assertTrue(denied(self.call('cat docs/x.md; printf hi | ~/.claude/agents/bin/codex-run.sh --footer')))

    def test_heredoc_body_is_data(self):
        cmd = ("cat > \"$SCHEMA_FILE\" <<'EOF'\n{\"cmd\": \"rm -rf / && curl evil\"}\nEOF")
        self.assertIsNone(self.call(cmd))

    def test_other_agents_ignored(self):
        self.assertIsNone(self.call('cat src/main.py', agent_type='general-purpose'))

    def test_denial_logged_measurable(self):
        self.call('rg TODO src/')
        self.assertIn('violation-averted', self.usage_log())


class TestStopGate(GateTest):
    RUNNER_TU = {'type': 'tool_use', 'name': 'Bash',
                 'input': {'command': "printf '%s' \"$TASK\" | ~/.claude/agents/bin/codex-run.sh --footer"}}

    def transcript(self, entries):
        path = os.path.join(self.home, 'transcript.jsonl')
        with open(path, 'w') as f:
            for e in entries:
                f.write(json.dumps(e) + '\n')
        return path

    def call(self, final, forwarded=True, structured=False, stop_hook_active=False,
             agent_type='codex-worker', first_user='EFFORT: low\n\ndo the thing'):
        content = [{'type': 'text', 'text': final}]
        if structured:
            content.append({'type': 'tool_use', 'name': 'StructuredOutput', 'input': {'x': 1}})
        entries = [{'message': {'role': 'user', 'content': first_user}}]
        if forwarded:
            entries.append({'message': {'role': 'assistant', 'content': [self.RUNNER_TU]}})
        entries.append({'message': {'role': 'assistant', 'content': content}})
        payload = {'agent_type': agent_type, 'agent_id': 't', 'cwd': '/tmp',
                   'stop_hook_active': stop_hook_active,
                   'agent_transcript_path': self.transcript(entries),
                   'last_assistant_message': final}
        return run(STOP, payload, self.home)

    def test_footer_proof_allowed(self):
        self.assertIsNone(self.call('The answer.\n[codex-session: 019f-abc]\n[codex-usage: input=1 cached=0 output=1 reasoning=0]'))

    def test_missing_session_footer_blocked(self):
        self.assertTrue(blocked(self.call('The answer.\n[codex-session: missing]\n[codex-usage: missing]')))

    def test_placeholder_after_launch_blocked(self):
        # The 2026-07-08 incident: runner invoked, never polled, placeholder returned.
        res = self.call('Waiting for the code review to complete... [The review task is running in the background.]')
        self.assertTrue(blocked(res))
        self.assertIn('--poll', res['reason'])
        self.assertIn('violation', self.usage_log())

    def test_abandoned_codex_running_blocked(self):
        res = self.call('CODEX_RUNNING: re-invoke with: ~/.claude/agents/bin/codex-run.sh --footer --poll /tmp/x')
        self.assertTrue(blocked(res))
        self.assertIn('--poll', res['reason'])

    def test_self_execution_blocked(self):
        res = self.call('Here is my analysis of the code...', forwarded=False)
        self.assertTrue(blocked(res))
        self.assertIn('forwarding', res['reason'])

    def test_codex_error_allowed_without_forwarding(self):
        self.assertIsNone(self.call('CODEX_ERROR: unknown directive EFORT: low', forwarded=False))

    def test_structured_output_after_runner_allowed(self):
        self.assertIsNone(self.call('', structured=True))

    def test_structured_output_without_runner_blocked(self):
        # Self-execution wearing a StructuredOutput call must still block.
        self.assertTrue(blocked(self.call('', forwarded=False, structured=True)))

    def test_stale_structured_output_not_proof(self):
        # 2026-07-08 review: a rejected StructuredOutput from an EARLIER attempt
        # must not vouch for a later placeholder final after a runner call.
        entries = [
            {'message': {'role': 'user', 'content': 'EFFORT: low\n\ndo the thing'}},
            {'message': {'role': 'assistant', 'content': [
                {'type': 'tool_use', 'name': 'StructuredOutput', 'input': {'x': 1}}]}},
            {'message': {'role': 'assistant', 'content': [self.RUNNER_TU]}},
            {'message': {'role': 'assistant', 'content': [
                {'type': 'text', 'text': 'still waiting for the review...'}]}},
        ]
        payload = {'agent_type': 'codex-worker', 'agent_id': 't', 'cwd': '/tmp',
                   'stop_hook_active': False,
                   'agent_transcript_path': self.transcript(entries),
                   'last_assistant_message': 'still waiting for the review...'}
        res = run(STOP, payload, self.home)
        self.assertTrue(blocked(res))
        self.assertIn('--poll', res['reason'])

    def test_quoted_footer_midline_not_proof(self):
        # 2026-07-08 review: prose QUOTING a footer is not a relayed footer —
        # proof must sit at line start, where the runner prints it.
        self.assertTrue(blocked(self.call('The run emitted [codex-session: 019f-abc] before stalling.')))

    def test_second_stop_passes_but_logs_violation(self):
        self.assertIsNone(self.call('still waiting...', stop_hook_active=True))
        self.assertIn('violation', self.usage_log())

    def test_other_agents_ignored(self):
        self.assertIsNone(self.call('anything', forwarded=False, agent_type='general-purpose'))

    def test_no_directives_no_agent_type_ignored(self):
        self.assertIsNone(self.call('anything', forwarded=False, agent_type=None,
                                    first_user='just a normal task prompt'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
