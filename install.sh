#!/usr/bin/env bash
# Install codex-worker into ~/.claude. Idempotent; backs up settings.json.
# Modes:
#   ./install.sh          install or update the managed files + merge hooks
#   ./install.sh --check  compare installed copies against this repo (drift
#                         report; exit 0 in sync, 2 on drift/missing)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE="$HOME/.claude"

managed_pairs() {
  # repo-relative path -> installed absolute path, one pair per line
  echo "agents/codex-worker.md $CLAUDE/agents/codex-worker.md"
  echo "agents/codex-worker-callers.md $CLAUDE/agents/codex-worker-callers.md"
  echo "agents/bin/codex-run.sh $CLAUDE/agents/bin/codex-run.sh"
  local f
  for f in "$REPO"/hooks/*.py; do
    echo "hooks/$(basename "$f") $CLAUDE/hooks/$(basename "$f")"
  done
  for f in "$REPO"/workflows/*.js; do
    echo "workflows/$(basename "$f") $CLAUDE/workflows/$(basename "$f")"
  done
}

if [[ "${1:-}" == "--check" ]]; then
  drift=0
  # ~/.claude itself must be a real directory, not a symlink — a link here
  # would let every managed path resolve through it and be reported OK.
  if [[ -L "$CLAUDE" ]]; then
    echo "SYMLINK  ~/.claude is a symlink ($(readlink "$CLAUDE")) — the config root must be a real directory"
    drift=1
  fi
  # Canonicalize the (real) base so symlinks ABOVE ~/.claude (e.g. a /home
  # symlink) don't false-positive; links at or below ~/.claude are drift —
  # readlink -f resolves every component, catching symlinked parent dirs
  # (e.g. ~/.claude/hooks -> elsewhere), not just leaf links.
  canon_base="$(readlink -f "$CLAUDE")"
  while read -r rel dest; do
    if [[ -e "$dest" && "$(readlink -f "$dest")" != "${dest/#$CLAUDE/$canon_base}" ]]; then
      echo "SYMLINK  $rel  (path resolves through a symlink, not a managed copy — remove the link and run ./install.sh)"
      drift=1
    elif [[ ! -f "$dest" ]]; then
      echo "MISSING  $rel  (expected at $dest)"
      drift=1
    elif ! cmp -s "$REPO/$rel" "$dest"; then
      echo "DRIFT    $rel  (installed copy differs — run ./install.sh after 'git pull')"
      drift=1
    else
      echo "OK       $rel"
    fi
  done < <(managed_pairs)
  if [[ -f "$REPO/.source-commit" ]]; then
    echo "repo: $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown) (upstream source $(cut -c1-7 "$REPO/.source-commit"))"
  fi
  if [[ $drift -eq 0 ]]; then echo "in sync"; exit 0; else echo "out of sync — git pull && ./install.sh"; exit 2; fi
fi

command -v codex >/dev/null || { echo "ERROR: codex CLI not found — install it and run 'codex login' first" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 required for the hooks" >&2; exit 1; }

mkdir -p "$CLAUDE/agents/bin" "$CLAUDE/hooks" "$CLAUDE/workflows" "$HOME/.codex-worker"

# Never write THROUGH a symlink: a link at (or above) a managed path would
# redirect these copies — and the settings rewrite below — outside ~/.claude.
# --check already reports such links; the install path must refuse them rather
# than follow them.
canon_base="$(readlink -f "$CLAUDE")"
for p in "$CLAUDE" "$CLAUDE/agents" "$CLAUDE/agents/bin" "$CLAUDE/hooks" "$CLAUDE/workflows" \
         "$CLAUDE/agents/codex-worker.md" "$CLAUDE/agents/codex-worker-callers.md" \
         "$CLAUDE/agents/bin/codex-run.sh" "$CLAUDE/settings.json"; do
  if [[ -L "$p" ]]; then
    echo "ERROR: $p is a symlink — refusing to install through it. Remove the link and re-run." >&2
    exit 1
  fi
  if [[ -e "$p" && "$(readlink -f "$p")" != "${p/#$CLAUDE/$canon_base}" ]]; then
    echo "ERROR: $p resolves outside the managed tree (symlinked parent) — refusing to install." >&2
    exit 1
  fi
done

cp "$REPO/agents/codex-worker.md" "$CLAUDE/agents/"
cp "$REPO/agents/codex-worker-callers.md" "$CLAUDE/agents/"
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

# v4: the SubagentStop stop-gate rides the AGENT FRONTMATTER in
# agents/codex-worker.md (fires on both the Agent and Workflow lanes), so it
# is no longer merged into settings.json — and an entry a pre-v4 install
# merged must be RETIRED or the gate double-fires on every stop.
WANTED = [
    ('PreToolUse', 'Workflow', hook('python3 ~/.claude/hooks/workflow-args-gate.py', 10)),
    ('PreToolUse', 'Bash', hook('python3 ~/.claude/hooks/codex-worker-bright-line.py', 5)),
    ('SubagentStart', 'codex-worker', hook('python3 ~/.claude/hooks/codex-worker-start-context.py', 5)),
]
hooks = settings.setdefault('hooks', {})
RETIRE = 'codex-worker-stop-gate.py'
kept_groups = []
for e in hooks.get('SubagentStop', []):
    kept = [x for x in e.get('hooks', []) if RETIRE not in x.get('command', '')]
    if kept:
        kept_groups.append({**e, 'hooks': kept})
if kept_groups:
    hooks['SubagentStop'] = kept_groups
else:
    hooks.pop('SubagentStop', None)
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
