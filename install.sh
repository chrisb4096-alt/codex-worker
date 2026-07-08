#!/usr/bin/env bash
# Install codex-worker into ~/.claude. Idempotent; backs up settings.json.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE="$HOME/.claude"

command -v codex >/dev/null || { echo "ERROR: codex CLI not found — install it and run 'codex login' first" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 required for the hooks" >&2; exit 1; }

mkdir -p "$CLAUDE/agents/bin" "$CLAUDE/hooks" "$CLAUDE/workflows" "$HOME/.codex-worker"
cp "$REPO/agents/codex-worker.md" "$CLAUDE/agents/"
cp "$REPO/agents/bin/codex-run.sh" "$CLAUDE/agents/bin/" && chmod +x "$CLAUDE/agents/bin/codex-run.sh"
cp "$REPO"/hooks/*.py "$CLAUDE/hooks/" && chmod +x "$CLAUDE"/hooks/codex-worker-*.py "$CLAUDE/hooks/workflow-args-gate.py"
cp "$REPO"/workflows/*.js "$CLAUDE/workflows/"

python3 - "$CLAUDE/settings.json" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
settings = {}
if os.path.exists(path):
    shutil.copy2(path, path + '.codex-worker.bak')
    with open(path) as f:
        settings = json.load(f)

def hook(cmd, timeout):
    return {'type': 'command', 'command': cmd, 'timeout': timeout}

WANTED = [
    ('PreToolUse', 'Workflow', hook('python3 ~/.claude/hooks/workflow-args-gate.py', 10)),
    ('PreToolUse', 'Bash', hook('python3 ~/.claude/hooks/codex-worker-bright-line.py', 5)),
    ('SubagentStop', None, hook('python3 ~/.claude/hooks/codex-worker-stop-gate.py', 15)),
    ('SubagentStart', 'codex-worker', hook('python3 ~/.claude/hooks/codex-worker-start-context.py', 5)),
]
hooks = settings.setdefault('hooks', {})
for event, matcher, h in WANTED:
    entries = hooks.setdefault(event, [])
    target = None
    for e in entries:
        if e.get('matcher') == matcher or (matcher is None and 'matcher' not in e):
            target = e
            break
    if target is None:
        target = {'hooks': []}
        if matcher is not None:
            target['matcher'] = matcher
        entries.append(target)
    if not any(x.get('command') == h['command'] for x in target['hooks']):
        target['hooks'].append(h)

with open(path, 'w') as f:
    json.dump(settings, f, indent=2)
print(f'hooks merged into {path} (backup at {path}.codex-worker.bak)' if os.path.exists(path + '.codex-worker.bak')
      else f'created {path}')
PY

echo "codex-worker installed. Sanity check the runner:"
echo "  printf 'say ok' | ~/.claude/agents/bin/codex-run.sh --footer --effort low"
echo "Then run the gate tests: python3 $REPO/tests/test_gates.py"
