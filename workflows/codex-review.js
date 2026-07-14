export const meta = {
  name: 'codex-review',
  description: 'Multi-dimension codex review of a diff with evidence-required adversarial verification',
  whenToUse: 'Reviewing staged/branch changes via codex-worker fan-out. args: {cwd: "/abs/repo", scope?: "staged"|"HEAD~1..HEAD"|"<git range>", focus?: "extra reviewer guidance", review_target?: "uncommitted"|"base=<branch>"|"commit=<sha>" — adds codex native-review leg; only pass a target that matches scope, e.g. uncommitted implies staged+unstaged+untracked}',
  phases: [
    { title: 'Find', detail: 'one finder per dimension + codex native review harness' },
    { title: 'Verify', detail: 'refute-framed verifiers, evidence required' },
  ],
}

// --- canonical codex-worker caller helpers (contract: ~/.claude/agents/codex-worker.md) ---
if (typeof args === 'string') { try { args = JSON.parse(args) } catch {} }
args = args || {}
if (!args.cwd || !String(args.cwd).startsWith('/')) throw new Error('args.cwd (absolute repo path) required — pass args as an object, not a JSON string')
const lint = (p) => { const m = p.match(/undefined\/|: undefined\b|\[object Object\]/); if (m) throw new Error('unresolved variable in prompt: ' + m[0]); return p }
const usedTokens = { input: 0, output: 0, reasoning: 0 }
const codexSessions = []
const runningLegs = []
const SESSION_RE = /^\[codex-session: ((?!missing)[0-9a-fA-F-]{8,})\]/m
// The runner APPENDS its footers after the model body, so the genuine session is
// the LAST match — task output can only plant [codex-session:] lines earlier in
// the body (mirror-gate round 4). Binding a security decision (archive path,
// verify_command) to the first match let planted text name a prior session.
const lastSession = (r) => {
  if (typeof r !== 'string') return null
  const m = [...r.matchAll(/^\[codex-session: (?!missing)([0-9a-fA-F-]{8,})\]/gm)]
  return m.length ? m[m.length - 1][1] : null
}
// A genuinely running leg emits ONLY the runner's CODEX_RUNNING line and NO
// session footer (the runner appends a footer only once the run completes). So a
// terminal body carrying a session footer is COMPLETE, never running — gating on
// footer-absence stops attacker model output (which rides a completed run's real
// footer) from being classified as running (mirror-gate round 5). The surfaced
// continuation is validated to the runner's exact --poll shape AND its CANONICAL
// path (~ / $HOME / the resolved home, then /.claude/agents/bin/codex-run.sh) — not
// any *…/codex-run.sh, which a command-substitution or attacker path in an injected
// CODEX_RUNNING line would satisfy and then steer the orchestrator's Bash into.
const RUNNER_HOME = (process.env.HOME || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const RUNNER_PATH = `(?:~|\\$HOME${RUNNER_HOME ? '|' + RUNNER_HOME : ''})/\\.claude/agents/bin/codex-run\\.sh`
const POLL_CONT = new RegExp(`^\\s*CODEX_RUNNING: re-invoke with: (${RUNNER_PATH} --footer --poll /tmp/codex-worker\\.(?!\\S*\\.\\.)[A-Za-z0-9._-]+)\\s*$`, 'm')
const isRunning = (r) => typeof r === 'string' && /^\s*CODEX_RUNNING:/.test(r) && !SESSION_RE.test(r)
const track = (r, label) => {
  const m = typeof r === 'string' && r.match(/^\[codex-usage: input=(\d+) cached=\d+ output=(\d+)(?: reasoning=(\d+))?/m)
  if (m) { usedTokens.input += +m[1]; usedTokens.output += +m[2]; usedTokens.reasoning += +(m[3] || 0) }
  const s = lastSession(r)
  if (s) codexSessions.push({ label: label || 'leg', session: s })
  if (isRunning(r)) { const c = r.match(POLL_CONT); runningLegs.push({ label: label || 'leg', continuation: c ? c[1] : null }) }
  return r
}
const proofReceipt = () => ({
  workflow_proof: {
    status: codexSessions.length ? 'VERIFY_REQUIRED' : 'NO_SESSIONS',
    required: true,
    sessions: codexSessions,
    verify_command: codexSessions.length ? '~/.claude/agents/bin/codex-run.sh --verify ' + codexSessions.map(s => s.session).join(',') : null,
    instruction: codexSessions.length ? 'REQUIRED corroboration: run verify_command before consuming results and discard any session marked forged — in the stop-gate one-shot fail-open window a fabricated footer passes parseCodex, and a session id absent from usage.log cannot be real.' : null,
  },
  running_legs: runningLegs,
})
// The envelope path is model-relayed TEXT. This workflow sets no OUTPUT_FILE, so
// the only path the runner can legitimately name is the archive keyed by the
// GENUINE (last) session — verify it rather than reading whatever the leg says,
// and never bind to a body-planted first footer (mirror-gate round 4).
const archiveOf = (session) => `${process.env.HOME}/.codex-worker/results/${session}.txt`
const parseCodex = (r) => {
  if (!r || typeof r !== 'string') return null
  if (r.trimStart().startsWith('CODEX_ERROR')) return null
  const s = lastSession(r)
  if (!s) return null                    // no session = codex never ran
  const files = [...r.matchAll(/^\[codex-final-file: (\S+) bytes=(\d+)\]/gm)]  // >8KB rode the file relay
  const f = files.length ? files[files.length - 1] : null
  if (f) return f[1] === archiveOf(s) ? { codex_file: f[1], codex_bytes: +f[2] } : null
  const cleaned = r.split('\n').filter(l => !/^\[codex-/.test(l)).join('\n')
  for (const [open, close] of [['{', '}'], ['[', ']']]) {
    const a = cleaned.indexOf(open), b = cleaned.lastIndexOf(close)
    if (a < 0 || b <= a) continue
    try { return JSON.parse(cleaned.slice(a, b + 1)) } catch {}
  }
  return null
}
// Spend caps (ops-readiness 2026-07-08): hard per-run ceilings so a runaway
// fan-out pauses with a receipt instead of spending silently. Override per run
// via args.max_agents / args.max_codex_tokens. Complements the harness
// `budget` global, which meters only Claude-side output tokens.
const CAPS = { agents: +args.max_agents || 80, codex_tokens: +args.max_codex_tokens || 10_000_000 }
let agentCalls = 0, capPause = null
const dispatch = async (p, opts) => {
  const spent = usedTokens.input + usedTokens.output
  const cap = agentCalls >= CAPS.agents ? 'max-agents' : spent >= CAPS.codex_tokens ? 'max-codex-tokens' : null
  if (cap) {
    if (!capPause) capPause = { paused_by: cap, first_blocked: opts.label || 'leg', agents_dispatched: agentCalls, codex_tokens_spent: spent, limits: CAPS, blocked: 0 }
    capPause.blocked++
    return null
  }
  agentCalls++
  return track(await agent(p, opts), opts.label)
}
// A still-running detached run returns CODEX_RUNNING (which parses to null);
// re-dispatching the same prompt would launch a DUPLICATE run (v3.7 audit).
// Only retry a clean failure, never a run that is still in flight.
const leg = async (effort, task, opts) => {
  const p = lint(['EFFORT: ' + effort, 'SANDBOX: read-only', 'CWD: ' + args.cwd, '', task].join('\n'))
  const raw1 = await dispatch(p, { ...opts, agentType: 'codex-worker' })
  let v = parseCodex(raw1)
  if (!v && !isRunning(raw1)) v = parseCodex(await dispatch(p, { ...opts, agentType: 'codex-worker', label: (opts.label || 'leg') + ':retry' }))
  return v
}

const scope = args.scope || 'staged'
const diffCmd = scope === 'staged' ? 'git diff --cached' : 'git diff ' + scope
const DIMS = [
  { key: 'correctness', prompt: 'logic errors, off-by-ones, wrong conditions, broken edge cases' },
  { key: 'silent-failure', prompt: 'swallowed errors, empty catches, fallbacks that hide defects, missing error paths' },
  { key: 'contracts', prompt: 'callers of changed interfaces, dropped/renamed fields, schema mismatches, dead references' },
  { key: 'tests', prompt: 'hedged assertions (assert x in (...)), phantom coverage claims, untested new branches' },
]

phase('Find')
const finders = DIMS.map(d => () =>
  leg('high', [
    'Review ONLY the changes shown by `' + diffCmd + '` in this repo for: ' + d.prompt + '.',
    args.focus ? 'Extra reviewer guidance: ' + args.focus : '',
    'Read surrounding code as needed to judge. Report only real defects, not style.',
    'Cap at 12 findings (keep the most severe); minified JSON, total output under 8KB.',
    'Output ONLY a single minified JSON object on one line, no fences, no prose:',
    '{"findings":[{"id":"' + d.key + '-1","file":"path","line":0,"summary":"...","failure_scenario":"concrete input/state -> wrong outcome"}]}',
  ].filter(Boolean).join('\n'), { label: 'sol:find:' + d.key, phase: 'Find' })
)
// Independent perspective: codex's native review harness (self-gathers its
// own diff, returns structured findings). OPT-IN via args.review_target: no
// native target matches the default 'staged' scope — 'uncommitted' also sweeps
// unstaged/untracked work, which leaks out-of-scope findings into confirmed[].
const nativeTarget = args.review_target || null
if (nativeTarget) finders.push(async () => {
  const p = lint(['EFFORT: high', 'CWD: ' + args.cwd, 'REVIEW: ' + nativeTarget].join('\n'))
  const raw1 = await dispatch(p, { agentType: 'codex-worker', label: 'sol:find:native-review', phase: 'Find' })
  let v = parseCodex(raw1)
  if (!v && !isRunning(raw1)) v = parseCodex(await dispatch(p, { agentType: 'codex-worker', label: 'sol:find:native-review:retry', phase: 'Find' }))
  if (v && v.codex_file) return v   // oversized: let the shared handler surface the file
  if (!v || !Array.isArray(v.findings)) return null
  return { findings: v.findings.map((f, i) => ({ ...normalizeFinding(f), id: 'native-' + (i + 1) })) }
})
// Finder legs occasionally disobey the requested shape and emit codex's
// native-review fields (title/body/code_location) — normalize every item so
// id/file never ride through undefined (2026-07-08: verify:undefined labels).
const relPath = (p) => String(p || '').startsWith(args.cwd + '/') ? String(p).slice(args.cwd.length + 1) : (p || '')
let rawSeq = 0
const normalizeFinding = (f) => ({
  id: f.id || 'raw-' + (++rawSeq),
  file: f.file || relPath(f.code_location && f.code_location.absolute_file_path),
  line: f.line || (f.code_location && f.code_location.line_range && f.code_location.line_range.start) || 0,
  summary: f.summary || f.title || '',
  failure_scenario: f.failure_scenario || f.body || '',
})
// A codex_file result means the leg blew the 8KB relay ceiling despite the
// cap instruction — its findings are on disk, not iterable here. Surface the
// path for the orchestrator instead of silently dropping the leg.
const oversized = []
const finderResults = await parallel(finders)
// A leg counts as OK only if it produced a real shape (a findings array or an
// oversized-output file). parseCodex can return a truthy `{}`/`[]` from a
// degenerate codex reply, which `filter(Boolean)` counted as success — every
// leg returning `{}` gave findersOk>0 with zero findings, sneaking back the
// exact clean-looking "found nothing" the guard below exists to catch (v3.7 review).
const findersOk = finderResults.filter(r => r && (Array.isArray(r.findings) || r.codex_file)).length
// All finders failing (no codex output) is NOT a clean review — returning
// confirmed:[] there masked total fan-out failure as "found nothing" (v3.7
// audit; the 2026-07-08 "0 findings from 44 candidates" class). Fail loud.
if (runningLegs.length) return { status: 'running', error: 'one or more finder legs are still running — poll the returned continuations; do not re-dispatch', finders_ok: findersOk, finders_total: finders.length, paused_by_cap: capPause, usage: usedTokens, ...proofReceipt() }
if (!findersOk) return { error: 'all ' + finders.length + ' finder legs failed to produce codex output — this is NOT a clean review; check ~/.codex-worker/usage.log before any re-run', finders_ok: 0, finders_total: finders.length, paused_by_cap: capPause, usage: usedTokens, ...proofReceipt() }
const rawFound = finderResults.filter(Boolean).flatMap(r => {
  if (r.codex_file) { oversized.push(r.codex_file); return [] }
  return (r.findings || []).filter(f => f && typeof f === 'object').map(normalizeFinding)
})
if (oversized.length) log('OVERSIZED finder output rode the file relay — orchestrator must read: ' + oversized.join(' '))
// Cross-finder dedupe on location — but never collapse findings without a
// real location (file ''/line 0 would all share one key and get dropped).
const seenLoc = new Set()
const found = rawFound.filter(f => {
  if (!f.file || !f.line) return true
  const k = f.file + ':' + f.line
  if (seenLoc.has(k)) return false
  seenLoc.add(k); return true
})
log(found.length + ' candidate findings (' + (rawFound.length - found.length) + ' cross-finder dupes dropped)')
// A clean 'complete' review requires EVERY dimension to have produced output and
// no spend-cap pause. One empty finder plus three cap-blocked ones is partial
// coverage, not "found nothing" — flag it so zero findings isn't read as clean
// (v3.7 high review; the 2026-07-08 "0 findings masks partial failure" class).
const partialWarn = () => 'only ' + findersOk + '/' + finders.length + ' review dimensions produced output' +
  (capPause ? ' (spend cap hit)' : '') + ' — partial coverage; zero/confirmed findings reflect only the dimensions that ran'
if (!found.length) {
  const incomplete = capPause || findersOk < finders.length
  return { status: incomplete ? 'incomplete' : 'complete', ...(incomplete ? { warning: partialWarn() } : {}),
    confirmed: [], refuted: [], finders_ok: findersOk, finders_total: finders.length, oversized_finder_files: oversized, paused_by_cap: capPause, usage: usedTokens, ...proofReceipt() }
}

phase('Verify')
const verdicts = await parallel(found.map(f => () =>
  leg('xhigh', [
    'Adversarially VERIFY this review finding — your default stance is that it is WRONG; confirm only if evidence forces you to.',
    'Finding: ' + JSON.stringify(f),
    'You MUST run commands (rg call sites, read the exact lines, run a test or a snippet where cheap) and report them as evidence. A verdict without commands_run is invalid.',
    'Output ONLY a single minified JSON object on one line, no fences, no prose:',
    '{"id":"' + f.id + '","verdict":"confirmed|refuted","reason":"...","commands_run":[{"cmd":"...","observed":"key output line"}]}',
  ].join('\n'), { label: 'sol:verify:' + f.id, phase: 'Verify' })
    .then(v => ({ finding: f, v }))
))
const judged = verdicts.filter(Boolean).map(({ finding, v }) => (
  v && v.codex_file
    // Verdict rode the file relay (>8KB) — preserve the path, don't downgrade.
    ? { ...finding, verdict: 'oversized-verifier-output', reason: 'verdict JSON is at codex_file — orchestrator must read it', evidence: [], codex_file: v.codex_file }
    : {
        ...finding,
        verdict: v && Array.isArray(v.commands_run) && v.commands_run.length ? v.verdict : 'invalid-no-evidence',
        reason: v ? v.reason : 'verifier failed twice',
        evidence: v ? v.commands_run : [],
      }
))
if (runningLegs.length) return { status: 'running', error: 'one or more verifier legs are still running — poll the returned continuations; do not trust partial verdicts', candidates: found, paused_by_cap: capPause, usage: usedTokens, ...proofReceipt() }
log('codex spend this run: input=' + usedTokens.input + ' output=' + usedTokens.output + ' (NOT in harness budget)')
if (capPause) log('PAUSED BY CAP: ' + capPause.paused_by + ' — ' + capPause.blocked + ' dispatches blocked after ' + capPause.agents_dispatched + ' agents / ' + capPause.codex_tokens_spent + ' codex tokens')
const incomplete = capPause || findersOk < finders.length
return {
  status: incomplete ? 'incomplete' : 'complete',
  ...(incomplete ? { warning: partialWarn() } : {}),
  confirmed: judged.filter(j => j.verdict === 'confirmed'),
  refuted: judged.filter(j => j.verdict === 'refuted'),        // keep — refutations prevent re-flagging
  needs_rework: judged.filter(j => j.verdict === 'invalid-no-evidence'),
  oversized_verdicts: judged.filter(j => j.verdict === 'oversized-verifier-output'),
  oversized_finder_files: oversized,
  finders_ok: findersOk,
  finders_total: finders.length,
  paused_by_cap: capPause,
  usage: usedTokens,
  ...proofReceipt(),
}
