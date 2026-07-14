#!/usr/bin/env python3
"""PreToolUse gate for the Workflow tool: stop bad args at dispatch.

Two deterministic checks, both upstream of every runtime guard:
1. Double-encoded args — a string whose PARSED value is itself a JSON-encoded
   object/array means the orchestrator stringified the payload twice; a single
   runtime JSON.parse still yields a string, property reads return undefined
   silently, and 'undefined' interpolates into agent prompts (2026-07-07
   incident: undefined/ dirs mkdir'd into two repos). A string that parses
   DIRECTLY to an object/array is NOT denied: some harness builds serialize
   correctly-passed object args before the hook sees them (2026-07-08 false-
   positive incident bricked every Workflow dispatch), so that shape is
   indistinguishable from a correct call here — the script-side parse-if-string
   guard (check 2) is the enforcement point that repairs it.
2. Unguarded args use — a script that reads args.* / args[...] must carry the
   parse-IF-STRING repair (typeof check + JSON.parse(args)). A throw-only
   guard is NOT enough: harness-serialized object args are a healthy shape,
   so throwing on string wastes the whole launch on a correct call (live-hit
   2026-07-13: a run died at 4ms on its own parse-or-throw guard and needed
   a manual script edit + resume).

Deny returns the reason to the model, which re-issues the call correctly.
Fail-open on anything unreadable — this gate must never block valid work.
One line per decision appended to workflow-gate.log.
"""
import json, os, re, sys, time

LOG = os.path.expanduser('~/.claude/hooks/workflow-gate.log')
# Any consumption of args: property/index access (args. args[ args?.),
# or args on the right of an assignment/destructure/comparison (= args,
# const {cwd} = args). Destructuring was a live miss (2026-07-08 review).
ARGS_USE = re.compile(r'\bargs\s*[.\[?]|=\s*args\b')
GUARD = 'typeof args'
# The repair half: a string args must be PARSED back to an object, not merely
# detected-and-thrown (throwing rejects healthy harness-serialized calls).
REPAIR = re.compile(r'JSON\s*\.\s*parse\s*\(\s*(?:String\s*\(\s*)?args')


def log(verdict, why):
    try:
        with open(LOG, 'a') as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {verdict} {why}\n")
    except OSError:
        pass


def deny(reason, why):
    log('deny', why)
    print(json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': reason,
        }
    }))
    sys.exit(0)


def script_text(ti):
    if ti.get('script'):
        return ti['script']
    path = ti.get('scriptPath')
    if not path and ti.get('name'):
        path = os.path.expanduser(f"~/.claude/workflows/{ti['name']}.js")
    if path:
        try:
            with open(os.path.expanduser(path)) as f:
                return f.read()
        except OSError:
            return None
    return None


def main():
    try:
        j = json.load(sys.stdin)
    except Exception:
        return
    if j.get('tool_name') != 'Workflow':
        return
    ti = j.get('tool_input') or {}

    why = 'ok'
    args = ti.get('args')
    if isinstance(args, str):
        s = args.strip()
        if s[:1] in '{["':
            try:
                parsed = json.loads(s)
            except Exception:
                parsed = None
            if isinstance(parsed, str):
                try:
                    inner = json.loads(parsed.strip())
                except Exception:
                    inner = None
                if isinstance(inner, (dict, list)):
                    deny('Workflow args is DOUBLE-ENCODED (a JSON string containing '
                         'a JSON-encoded object/array); one runtime parse still '
                         'yields a string, property reads return undefined silently '
                         "and interpolate as literal 'undefined' into agent prompts. "
                         'Re-issue the call passing the object/array itself as args '
                         f'(no quoting/escaping): args: {s[:200]}',
                         'double-encoded args')
            elif isinstance(parsed, (dict, list)):
                # Correct object args arrive here as a serialized string on some
                # harness builds — indistinguishable from a caller-stringified
                # payload, so allow and rely on the script guard (check 2).
                why = 'args string parses to object — runtime guard governs'

    script = script_text(ti)
    if script and ARGS_USE.search(script) and (GUARD not in script or not REPAIR.search(script)):
        why = ('unguarded args use in script' if GUARD not in script
               else 'throw-only args guard (no JSON.parse repair)')
        deny('Workflow script reads args.* without the parse-IF-STRING repair. '
             'The harness may serialize object args before the script sees them, '
             'so a throw-on-string guard rejects healthy calls — the script must '
             'PARSE instead. Open the script body with:\n'
             "if (typeof args === 'string') { try { args = JSON.parse(args) } catch {} }\n"
             "if (!args?.<required-key>) throw new Error('args.<required-key> required — "
             "pass args as a real object')\n"
             'then re-issue the call.',
             why)

    log('allow', why)


if __name__ == '__main__':
    main()
