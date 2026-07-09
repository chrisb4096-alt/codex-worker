#!/usr/bin/env bash
# codex-run.sh — deterministic runner for the codex-worker contract (v3.6).
# v3.6 (2026-07-09): default model gpt-5.5 -> gpt-5.6-sol; default effort
# medium -> high; effort enum extended to none|low|medium|high|xhigh|max|ultra
# (all live-verified on codex 0.144.0; ultra = codex-native multi-agent
# orchestration, ~4 parallel agents).
# Launch mode: reads the task text on stdin, launches codex detached, polls.
# Poll mode (--poll <scratch>): resumes polling a still-running launch.
# Recover mode (--recover <session-id>): re-emit a completed run's content +
# footers from the archive + usage.log — the mechanical fix when a relay was
# stripped or lost (never retype results from memory).
# Review mode (--review uncommitted|custom|base=<branch>|commit=<sha>): runs
# codex's native review harness in an isolated CODEX_HOME; results extracted
# from session rollouts (review has no --json/-o on codex 0.142.x).
# Default output: delimited envelope block. --footer: caller-contract format
# (content + [codex-session:]/[codex-usage:] footers) for the codex-worker
# agent to return verbatim; see ~/.claude/agents/codex-worker.md.
# File relay (v3.3): every ok result is archived to
# $WORKER_HOME/results/<session>.txt (pruned after 7 days). In --footer mode,
# content larger than CODEX_RELAY_MAX bytes (default 8192 — the measured
# haiku verbatim-relay ceiling, 2026-07-07 incident) or any --output-file run
# replaces the inline content with a one-line envelope
# `[codex-final-file: <path> bytes=<n>]` that the wrapper can relay reliably.
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODEL=gpt-5.6-sol EFFORT=high SANDBOX=workspace-write CWD="$PWD"
NETWORK=0 MCP="" SCHEMA="" SCHEMA_FILE="" RESUME="" RETRY_SAFE=0
POLL="" BUDGET=540 FOOTER=0 REVIEW="" EXTRACT="" OUTPUT_FILE="" RECOVER=""
WORKER_HOME="$HOME/.codex-worker"
RELAY_MAX="${CODEX_RELAY_MAX:-8192}"
case "$RELAY_MAX" in ''|*[!0-9]*) RELAY_MAX=8192 ;; esac

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --effort) EFFORT=$2; shift 2 ;;
    --sandbox) SANDBOX=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --mcp) MCP=$2; shift 2 ;;
    --schema) SCHEMA=$2; shift 2 ;;
    --schema-file) SCHEMA_FILE=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --review) REVIEW=$2; shift 2 ;;
    --output-file) OUTPUT_FILE=$2; shift 2 ;;
    --retry-safe) RETRY_SAFE=1; shift ;;
    --poll) POLL=$2; shift 2 ;;
    --recover) RECOVER=$2; shift 2 ;;
    --poll-budget) BUDGET=$2; shift 2 ;;
    --footer) FOOTER=1; shift ;;
    --extract-review) EXTRACT=$2; shift 2 ;;
    *) echo "CODEX_ERROR: unknown flag $1" >&2; exit 2 ;;
  esac
done

# Internal: called by the detached run.sh after codex review exits. Pulls the
# final review text + token usage out of the run's isolated session rollouts
# into last.txt / telemetry (review mode has no -o/--json to capture directly).
if [ -n "$EXTRACT" ]; then
  python3 - "$EXTRACT" <<'PYEOF'
import glob, json, re, sys
S = sys.argv[1]
try:
    log = open(f"{S}/events.jsonl", errors="replace").read()
except OSError:
    log = ""
m = re.search(r'^session id: (\S+)$', log, re.M)
session = m.group(1) if m else "missing"
last, fallback, totals = None, None, {}
for f in sorted(glob.glob(f"{S}/home/sessions/*/*/*/rollout-*.jsonl")):
    file_usage = None
    for line in open(f, errors="replace"):
        try:
            p = (json.loads(line).get("payload") or {})
        except Exception:
            continue
        if p.get("type") == "task_complete" and p.get("last_agent_message"):
            if session != "missing" and session in f:
                last = p["last_agent_message"]
            else:
                fallback = p["last_agent_message"]
        elif p.get("type") == "token_count":
            u = (p.get("info") or {}).get("total_token_usage")
            if u:
                file_usage = u  # last one per file is that session's total
    if file_usage:
        for k, v in file_usage.items():
            totals[k] = totals.get(k, 0) + v
last = last or fallback
if last:
    open(f"{S}/last.txt", "w").write(last)
usage = "missing"
if totals:
    usage = (f"input={totals.get('input_tokens', 0)} "
             f"cached={totals.get('cached_input_tokens', 0)} "
             f"output={totals.get('output_tokens', 0)} "
             f"reasoning={totals.get('reasoning_output_tokens', 0)}")
open(f"{S}/telemetry", "w").write(f"{session}\n{usage}\n")
PYEOF
  exit $?
fi

# Recover mode: re-emit a completed run's caller-contract output from the
# archive (content) + usage.log (telemetry). Deterministic — no model in the
# loop — so a wrapper whose relay was stripped/garbled can regenerate the
# exact footer block instead of retyping from memory (2026-07-08: 4 legs ran
# ok but returned footer-less finals; recovery via cat was gate-denied).
if [ -n "$RECOVER" ]; then
  case "$RECOVER" in
    *[!0-9a-fA-F-]*|'') echo "CODEX_ERROR: --recover takes a session id, got '$RECOVER'"; exit 2 ;;
  esac
  ARCHIVE="$WORKER_HOME/results/$RECOVER.txt"
  [ -f "$ARCHIVE" ] || { echo "CODEX_ERROR: no archived result for session $RECOVER (archive keeps 7 days; check $WORKER_HOME/usage.log for the ok line)"; exit 2; }
  LINE=$(grep -F "ok session=$RECOVER " "$WORKER_HOME/usage.log" 2>/dev/null | tail -1)
  USAGE=$(printf '%s' "$LINE" | grep -oE 'input=[0-9]+ cached=[0-9]+ output=[0-9]+ reasoning=[0-9]+' | head -1)
  [ -n "$USAGE" ] || USAGE=missing
  BYTES=$(wc -c < "$ARCHIVE")
  if [ "$BYTES" -gt "$RELAY_MAX" ]; then
    echo "[codex-final-file: $ARCHIVE bytes=$BYTES]"
  else
    cat "$ARCHIVE"; echo
  fi
  echo "[codex-session: $RECOVER]"
  echo "[codex-usage: $USAGE]"
  FILES=$(printf '%s' "$LINE" | grep -oE ' files=[0-9]+' | grep -oE '[0-9]+')
  [ -n "$FILES" ] && echo "[codex-files-written: $FILES]"
  exit 0
fi

# Reject garbage before it becomes a real directory or generated shell: an
# interpolated-undefined CWD must never be mkdir'd (2026-07-07 incident), and
# directive values are written inside single quotes in run.sh, so quotes/
# newlines in any value would break out of the generated script.
if [ -z "$POLL" ]; then
  case "$CWD" in
    undefined|null|NaN|'') echo "CODEX_ERROR: invalid --cwd '$CWD' (unresolved orchestrator variable?)" >&2; exit 2 ;;
    /*) : ;;
    *) echo "CODEX_ERROR: --cwd must be an absolute path, got '$CWD'" >&2; exit 2 ;;
  esac
  case "/$CWD/" in
    */undefined/*|*/null/*|*/NaN/*) echo "CODEX_ERROR: --cwd '$CWD' contains an unresolved placeholder segment" >&2; exit 2 ;;
  esac
  if [ -n "$OUTPUT_FILE" ]; then
    case "$OUTPUT_FILE" in
      /*) : ;;
      *) echo "CODEX_ERROR: --output-file must be an absolute path, got '$OUTPUT_FILE'" >&2; exit 2 ;;
    esac
    case "$OUTPUT_FILE" in
      *[[:space:]]*) echo "CODEX_ERROR: --output-file must not contain whitespace: '$OUTPUT_FILE'" >&2; exit 2 ;;
    esac
    case "/$OUTPUT_FILE/" in
      */undefined/*|*/null/*|*/NaN/*) echo "CODEX_ERROR: --output-file '$OUTPUT_FILE' contains an unresolved placeholder segment" >&2; exit 2 ;;
    esac
  fi
  for v in "$CWD" "$MODEL" "$RESUME" "$MCP" "$EFFORT" "$SANDBOX" "$REVIEW" "$OUTPUT_FILE"; do
    case "$v" in *\'*|*\"*|*\`*|*\$*|*\\*|*$'\n'*|*$'\r'*)
      echo "CODEX_ERROR: directive value contains shell metacharacters: $v" >&2; exit 2 ;;
    esac
  done
  case "$EFFORT" in none|low|medium|high|xhigh|max|ultra) : ;; *) echo "CODEX_ERROR: invalid --effort '$EFFORT'" >&2; exit 2 ;; esac
  case "$SANDBOX" in read-only|workspace-write) : ;; *) echo "CODEX_ERROR: invalid --sandbox '$SANDBOX'" >&2; exit 2 ;; esac
  if [ -n "$REVIEW" ]; then
    case "$REVIEW" in
      uncommitted|custom) : ;;
      base=?*) case "${REVIEW#base=}" in *[!A-Za-z0-9._/-]*) echo "CODEX_ERROR: invalid --review base branch '${REVIEW#base=}'" >&2; exit 2 ;; esac ;;
      commit=?*) case "${REVIEW#commit=}" in *[!0-9a-fA-F]*) echo "CODEX_ERROR: invalid --review commit sha '${REVIEW#commit=}'" >&2; exit 2 ;; esac ;;
      *) echo "CODEX_ERROR: invalid --review '$REVIEW' (use uncommitted|custom|base=<branch>|commit=<sha>)" >&2; exit 2 ;;
    esac
    [ -n "$RESUME" ] && { echo "CODEX_ERROR: --review cannot combine with --resume" >&2; exit 2; }
    [ -n "$MCP" ] && { echo "CODEX_ERROR: --review cannot combine with --mcp" >&2; exit 2; }
    [ "$NETWORK" = 1 ] && { echo "CODEX_ERROR: --review cannot combine with --network" >&2; exit 2; }
    [ -n "$SCHEMA$SCHEMA_FILE" ] && [ "$REVIEW" != custom ] && { echo "CODEX_ERROR: --schema requires --review custom (targeted reviews use codex's canned prompt)" >&2; exit 2; }
    SANDBOX=read-only   # the review harness is read-only by construction
  fi
fi

scan_events() { # $1=scratch -> sets SESSION, USAGE
  SESSION="missing" USAGE="missing"
  if [ -f "$1/telemetry" ]; then   # review mode: written by --extract-review
    SESSION=$(sed -n 1p "$1/telemetry"); USAGE=$(sed -n 2p "$1/telemetry")
    [ -n "$SESSION" ] || SESSION="missing"; [ -n "$USAGE" ] || USAGE="missing"
    return 0
  fi
  [ -f "$1/events.jsonl" ] || return 0
  SESSION=$(grep -m1 -oE '"(thread_id|session_id)":"[^"]*"' "$1/events.jsonl" | cut -d'"' -f4)
  [ -n "$SESSION" ] || SESSION="missing"
  local uo; uo=$(grep -o '"type":"turn.completed".*' "$1/events.jsonl" | tail -1)
  if [ -n "$uo" ]; then
    n() { printf '%s' "$uo" | grep -o "\"$1\":[0-9]*" | head -1 | grep -o '[0-9]*$'; }
    USAGE="input=$(n input_tokens) cached=$(n cached_input_tokens) output=$(n output_tokens) reasoning=$(n reasoning_output_tokens)"
  fi
}

files_written() { # $1=scratch -> prints changed-file list (workspace-write only)
  [ "$(sed -n 2p "$1/meta")" = workspace-write ] || return 0
  find "$(sed -n 1p "$1/meta")" \( -name .git -o -name node_modules \) -prune \
    -o -type f -newer "$1/marker" -print 2>/dev/null | head -200
}

prepare_final() { # $1=scratch -> sets RELAY(inline|file), FINAL_FILE, BYTES, ARCHIVE, KEEP_SCRATCH
  RELAY=inline FINAL_FILE="" ARCHIVE=""
  BYTES=$(wc -c < "$1/last.txt" 2>/dev/null || echo 0)
  local out; out=$(sed -n 3p "$1/meta" 2>/dev/null)
  if [ "$SESSION" != missing ] && mkdir -p "$WORKER_HOME/results" 2>/dev/null \
     && cp "$1/last.txt" "$WORKER_HOME/results/.$SESSION.tmp" 2>/dev/null \
     && mv "$WORKER_HOME/results/.$SESSION.tmp" "$WORKER_HOME/results/$SESSION.txt" 2>/dev/null; then
    ARCHIVE="$WORKER_HOME/results/$SESSION.txt"
  fi
  if [ -n "$out" ] && mkdir -p "$(dirname "$out")" 2>/dev/null \
     && cp "$1/last.txt" "$out" 2>/dev/null; then
    RELAY=file FINAL_FILE="$out"
  elif [ "$FOOTER" = 1 ] && [ "$BYTES" -gt "$RELAY_MAX" ]; then
    # Oversized inline relay is the proven haiku failure mode — NEVER fall
    # back to it. If the archive copy failed, point at the scratch copy and
    # keep the scratch dir alive instead.
    if [ -n "$ARCHIVE" ]; then RELAY=file FINAL_FILE="$ARCHIVE"
    else RELAY=file FINAL_FILE="$1/last.txt" KEEP_SCRATCH=1; fi
  fi
}

emit_final_content() { # $1=scratch — envelope or inline last.txt (shared by both emitters)
  if [ "$RELAY" = file ]; then
    echo "[codex-final-file: $FINAL_FILE bytes=$BYTES]"
  else
    cat "$1/last.txt"; echo
  fi
}

emit_footer() { # $1=status $2=scratch
  if [ "$1" = ok ]; then
    emit_final_content "$2"
    echo "[codex-session: $SESSION]"
    echo "[codex-usage: $USAGE]"
    [ -n "$FILES_N" ] && echo "[codex-files-written: $FILES_N]"
  elif [ "$1" = running ]; then
    echo "CODEX_RUNNING: re-invoke with: $0 --footer --poll $2"
  else
    echo "CODEX_ERROR: codex exec failed (exit $(cat "$2/exit" 2>/dev/null || echo '?'), usage=$USAGE). events tail:"
    tail -30 "$2/events.jsonl" 2>/dev/null
    echo "[codex-scratch: $2]"
  fi
}

emit_envelope() { # $1=status $2=scratch $3=keep
  echo "===CODEX_RESULT==="
  echo "STATUS: $1"
  echo "SESSION: $SESSION"
  echo "USAGE: $USAGE"
  [ "$3" = yes ] && echo "SCRATCH: $2"
  if [ "$1" = ok ] && [ "$(sed -n 2p "$2/meta")" = workspace-write ]; then
    local files; files=$(files_written "$2")
    echo "FILES_WRITTEN: $(printf '%s' "$files" | grep -c .)"
    [ -n "$files" ] && printf '%s\n' "$files"
  fi
  echo "===FINAL==="
  if [ "$1" = ok ]; then
    emit_final_content "$2"
  elif [ "$1" = running ]; then
    echo "still running; re-invoke with: codex-run.sh --poll $2"
  else
    echo "CODEX_ERROR: codex exec failed (exit $(cat "$2/exit" 2>/dev/null || echo '?'), usage=$USAGE). events tail:"
    tail -30 "$2/events.jsonl" 2>/dev/null
  fi
  echo "===END==="
}

emit_block() { # $1=status $2=scratch $3=keep (yes|no)
  local status=$1 S=$2 keep=$3
  scan_events "$S"
  # ok must always carry real proof: callers gate on a non-missing session.
  if [ "$status" = ok ] && { [ "$USAGE" = missing ] || [ "$SESSION" = missing ]; }; then
    status=error; keep=yes
  fi
  RELAY=inline FINAL_FILE="" BYTES=0 ARCHIVE="" KEEP_SCRATCH=0 FILES_N=""
  [ "$status" = ok ] && prepare_final "$S"
  # FILES_N feeds the footer emitter + usage.log; only footer mode uses it, and
  # envelope mode runs its own files_written for the file LIST — computing it
  # here for envelope mode too would traverse the workspace twice (v3.5 review).
  [ "$FOOTER" = 1 ] && [ "$status" = ok ] && [ "$(sed -n 2p "$S/meta")" = workspace-write ] && FILES_N=$(files_written "$S" | grep -c .)
  [ "$KEEP_SCRATCH" = 1 ] && keep=yes
  [ "$status" = running ] || { mkdir -p "$WORKER_HOME" && echo "$(date -Is) $status session=$SESSION $USAGE${FILES_N:+ files=$FILES_N} cwd=$(sed -n 1p "$S/meta" 2>/dev/null)${ARCHIVE:+ file=$ARCHIVE}" >> "$WORKER_HOME/usage.log"; } 2>/dev/null
  if [ "$FOOTER" = 1 ]; then emit_footer "$status" "$S"; else emit_envelope "$status" "$S" "$keep"; fi
  [ "$status" = ok ] && [ "$keep" = no ] && rm -rf "$S"
}

if [ -n "$POLL" ]; then
  S=$POLL
  [ -f "$S/meta" ] || { echo "CODEX_ERROR: no launch found at $S" >&2; exit 2; }
else
  S=$(mktemp -d /tmp/codex-worker.XXXXXX)
  cat > "$S/task.txt"
  if [ -n "$REVIEW" ] && [ "$REVIEW" != custom ]; then
    # Targeted reviews use codex's canned prompt; 0.142.x cannot combine a
    # custom prompt with --uncommitted/--base/--commit.
    [ -s "$S/task.txt" ] && { echo "CODEX_ERROR: REVIEW '$REVIEW' cannot take task text on codex 0.142.x — use 'REVIEW: custom' (your instructions, reviews uncommitted changes) or drop the task text" >&2; rm -rf "$S"; exit 2; }
  else
    [ -s "$S/task.txt" ] || { echo "CODEX_ERROR: empty task on stdin" >&2; rm -rf "$S"; exit 2; }
  fi
  # Schema rides in the task text, not --output-schema: codex's native flag
  # demands OpenAI strict mode (additionalProperties:false, all props required),
  # which breaks optional fields and would make codex invent telemetry values.
  if [ -n "$SCHEMA_FILE" ]; then
    SCHEMA=$(cat "$SCHEMA_FILE" 2>/dev/null) || { echo "CODEX_ERROR: cannot read --schema-file $SCHEMA_FILE" >&2; rm -rf "$S"; exit 2; }
  fi
  [ -n "$SCHEMA" ] && printf '\n\nOutput ONLY a single minified JSON object on one line conforming to this JSON Schema — no markdown fences, no prose before or after:\n%s\n' "$SCHEMA" >> "$S/task.txt"
  mkdir -p "$CWD" || { echo "CODEX_ERROR: cannot create CWD $CWD" >&2; exit 2; }
  printf '%s\n%s\n%s\n' "$CWD" "$SANDBOX" "$OUTPUT_FILE" > "$S/meta"
  touch "$S/marker"
  # Retention: results archive self-prunes; 7 days covers any recovery window.
  find "$WORKER_HOME/results" -type f -mtime +7 -delete 2>/dev/null

  if [ -n "$REVIEW" ]; then
    # Isolated CODEX_HOME: session rollouts are this run's only, so the
    # extractor can't pick up a concurrent run's telemetry.
    mkdir -p "$S/home"
    cp "$HOME/.codex/auth.json" "$S/home/auth.json" 2>/dev/null
    HOME_LINE="export CODEX_HOME='$S/home'"
    case "$REVIEW" in
      uncommitted) RFLAGS="--uncommitted" ;;
      custom)      RFLAGS="-" ;;
      base=*)      RFLAGS="--base '${REVIEW#base=}'" ;;
      commit=*)    RFLAGS="--commit '${REVIEW#commit=}'" ;;
    esac
    CMD="codex review -c model='$MODEL' -c model_reasoning_effort='$EFFORT' $RFLAGS"
    if [ "$REVIEW" = custom ]; then CMD="$CMD < '$S/task.txt'"; else CMD="$CMD < /dev/null"; fi
    CMD="$CMD > '$S/events.jsonl' 2>&1"
    POST_CMD="'$SELF' --extract-review '$S' >/dev/null 2>&1"
  else
    # Minimal CODEX_HOME unless MCP servers are needed (they live in the full config).
    HOME_LINE=""
    if [ -z "$MCP" ] && [ -d "$WORKER_HOME" ]; then
      cp -u "$HOME/.codex/auth.json" "$WORKER_HOME/auth.json" 2>/dev/null
      HOME_LINE="export CODEX_HOME='$WORKER_HOME'"
    fi
    if [ -n "$RESUME" ]; then
      # resume has no --sandbox flag; enforce the directives via config overrides.
      CMD="codex exec resume '$RESUME' -m '$MODEL' -c model_reasoning_effort='$EFFORT' -c sandbox_mode='$SANDBOX' --skip-git-repo-check --json"
    else
      CMD="codex exec -m '$MODEL' -c model_reasoning_effort='$EFFORT' --sandbox '$SANDBOX' -C '$CWD' --skip-git-repo-check --json"
    fi
    [ "$NETWORK" = 1 ] && CMD="$CMD -c sandbox_workspace_write.network_access=true"
    if [ -n "$MCP" ]; then
      for m in $(printf '%s' "$MCP" | tr ',' ' '); do
        CMD="$CMD -c 'mcp_servers.$m.default_tools_approval_mode=\"approve\"'"
      done
    fi
    # Task rides on stdin (file redirect): argv would cap it at MAX_ARG_STRLEN
    # (~128KiB) and an open-but-empty stdin is the codex#20919 hang.
    CMD="$CMD -o '$S/last.txt' < '$S/task.txt' > '$S/events.jsonl' 2>&1"
    POST_CMD=":"
  fi

  OTHER_LEFT=0
  case "$CWD" in /tmp/*) RETRY_SAFE=1 ;; esac
  { [ "$SANDBOX" = read-only ] || [ "$RETRY_SAFE" = 1 ]; } && OTHER_LEFT=1

  cat > "$S/run.sh" <<RUNNER
#!/usr/bin/env bash
echo \$\$ > '$S/pid'
cd '$CWD' || { echo 127 > '$S/exit'; touch '$S/DONE'; exit; }
$HOME_LINE
rl_left=2; other_left=$OTHER_LEFT
while :; do
  rm -f '$S/last.txt' '$S/telemetry'
  $CMD
  rc=\$?
  $POST_CMD
  if [ \$rc -eq 0 ] && [ -s '$S/last.txt' ]; then echo 0 > '$S/exit'; break; fi
  # Transient-classify only real nonzero exits: on rc=0+empty-result the log
  # tail is model/prompt text, and task text quoting these tokens has caused
  # live misclassification. A failed loop must never write exit 0.
  if [ \$rc -ne 0 ] && tail -n 40 '$S/events.jsonl' | grep -qiE 'rate_limit|usage_limit|overloaded|too many requests|"429"'; then
    if [ \$rl_left -gt 0 ]; then rl_left=\$((rl_left-1)); sleep \$((RANDOM%16+15)); continue; fi
  elif [ \$other_left -gt 0 ]; then other_left=0; continue; fi
  [ \$rc -eq 0 ] && rc=1
  echo \${rc:-1} > '$S/exit'; break
done
touch '$S/DONE'
RUNNER
  chmod +x "$S/run.sh"
  nohup setsid bash "$S/run.sh" >/dev/null 2>&1 &
fi

end=$((SECONDS + BUDGET))
while [ ! -f "$S/DONE" ] && [ $SECONDS -lt $end ]; do sleep 1; done

if [ ! -f "$S/DONE" ]; then
  emit_block running "$S" yes
elif [ "$(cat "$S/exit" 2>/dev/null)" = 0 ]; then
  emit_block ok "$S" no
else
  emit_block error "$S" yes
fi
