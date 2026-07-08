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
const track = (r) => {
  const m = typeof r === 'string' && r.match(/^\[codex-usage: input=(\d+) cached=\d+ output=(\d+)(?: reasoning=(\d+))?/m)
  if (m) { usedTokens.input += +m[1]; usedTokens.output += +m[2]; usedTokens.reasoning += +(m[3] || 0) }
  return r
}
const parseCodex = (r) => {
  if (!r || typeof r !== 'string') return null
  if (r.trimStart().startsWith('CODEX_ERROR')) return null
  if (!/^\[codex-session: (?!missing)\S+\]/m.test(r)) return null   // no session = codex never ran
  const f = r.match(/^\[codex-final-file: (\S+) bytes=(\d+)\]/m)    // >8KB rode the file relay
  if (f) return { codex_file: f[1], codex_bytes: +f[2] }
  const cleaned = r.split('\n').filter(l => !/^\[codex-/.test(l)).join('\n')
  const a = cleaned.indexOf('{'), b = cleaned.lastIndexOf('}')
  if (a < 0 || b <= a) return null
  try { return JSON.parse(cleaned.slice(a, b + 1)) } catch { return null }
}
const leg = async (effort, task, opts) => {
  const p = lint(['EFFORT: ' + effort, 'SANDBOX: read-only', 'CWD: ' + args.cwd, '', task].join('\n'))
  let v = parseCodex(track(await agent(p, { agentType: 'codex-worker', ...opts })))
  if (!v) v = parseCodex(track(await agent(p, { agentType: 'codex-worker', ...opts, label: (opts.label || 'leg') + ':retry' })))
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
  ].filter(Boolean).join('\n'), { label: 'gpt-5.5:find:' + d.key, phase: 'Find' })
)
// Independent perspective: codex's native review harness (self-gathers its
// own diff, returns structured findings). OPT-IN via args.review_target: no
// native target matches the default 'staged' scope — 'uncommitted' also sweeps
// unstaged/untracked work, which leaks out-of-scope findings into confirmed[].
const nativeTarget = args.review_target || null
if (nativeTarget) finders.push(async () => {
  const p = lint(['EFFORT: medium', 'CWD: ' + args.cwd, 'REVIEW: ' + nativeTarget].join('\n'))
  let v = parseCodex(track(await agent(p, { agentType: 'codex-worker', label: 'gpt-5.5:find:native-review', phase: 'Find' })))
  if (!v) v = parseCodex(track(await agent(p, { agentType: 'codex-worker', label: 'gpt-5.5:find:native-review:retry', phase: 'Find' })))
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
const rawFound = (await parallel(finders)).filter(Boolean).flatMap(r => {
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
if (!found.length) return { confirmed: [], refuted: [], oversized_finder_files: oversized, usage: usedTokens }

phase('Verify')
const verdicts = await parallel(found.map(f => () =>
  leg('high', [
    'Adversarially VERIFY this review finding — your default stance is that it is WRONG; confirm only if evidence forces you to.',
    'Finding: ' + JSON.stringify(f),
    'You MUST run commands (rg call sites, read the exact lines, run a test or a snippet where cheap) and report them as evidence. A verdict without commands_run is invalid.',
    'Output ONLY a single minified JSON object on one line, no fences, no prose:',
    '{"id":"' + f.id + '","verdict":"confirmed|refuted","reason":"...","commands_run":[{"cmd":"...","observed":"key output line"}]}',
  ].join('\n'), { label: 'gpt-5.5:verify:' + f.id, phase: 'Verify' })
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
log('codex spend this run: input=' + usedTokens.input + ' output=' + usedTokens.output + ' (NOT in harness budget)')
return {
  confirmed: judged.filter(j => j.verdict === 'confirmed'),
  refuted: judged.filter(j => j.verdict === 'refuted'),        // keep — refutations prevent re-flagging
  needs_rework: judged.filter(j => j.verdict === 'invalid-no-evidence'),
  oversized_verdicts: judged.filter(j => j.verdict === 'oversized-verifier-output'),
  oversized_finder_files: oversized,
  usage: usedTokens,
}
