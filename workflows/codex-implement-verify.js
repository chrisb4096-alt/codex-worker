export const meta = {
  name: 'codex-implement-verify',
  description: 'Codex implementation legs, each mechanically post-verified (call sites, test deltas, live path)',
  whenToUse: 'Fan-out implementation with anti-rubber-stamp verification. args: {tasks: [{id, cwd: "/abs", spec, effort?: "high"|"xhigh", test_cmd?}]}',
  phases: [
    { title: 'Pin', detail: 'spark pins pre-run git state per task' },
    { title: 'Implement', detail: 'workspace-write codex writers (no commit/push)' },
    { title: 'Post-verify', detail: 'mechanical checks: callers, test counts, live run, git reconcile' },
  ],
}

if (typeof args === 'string') { try { args = JSON.parse(args) } catch {} }
args = args || {}
if (!Array.isArray(args.tasks) || !args.tasks.length) throw new Error('args.tasks[] required — pass args as an object, not a JSON string')
for (const t of args.tasks) {
  if (!t.cwd || !String(t.cwd).startsWith('/')) throw new Error('task ' + t.id + ': absolute cwd required')
  if (!t.spec || typeof t.spec !== 'string') throw new Error('task ' + t.id + ': spec (string) required')
}
const lint = (p) => { const m = p.match(/undefined\/|: undefined\b|\[object Object\]/); if (m) throw new Error('unresolved variable in prompt: ' + m[0]); return p }
const usedTokens = { input: 0, output: 0, reasoning: 0 }
const track = (r) => {
  const m = typeof r === 'string' && r.match(/^\[codex-usage: input=(\d+) cached=\d+ output=(\d+)(?: reasoning=(\d+))?/m)
  if (m) { usedTokens.input += +m[1]; usedTokens.output += +m[2]; usedTokens.reasoning += +(m[3] || 0) }
  return r
}
const gate = (r) => {
  if (!r || typeof r !== 'string') return null
  if (r.trimStart().startsWith('CODEX_ERROR')) return null
  if (!/^\[codex-session: (?!missing)\S+\]/m.test(r)) return null
  return r
}
const jsonOf = (r) => {
  const f = r.match(/^\[codex-final-file: (\S+) bytes=(\d+)\]/m)   // >8KB rode the file relay
  if (f) return { codex_file: f[1], codex_bytes: +f[2] }
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
const CAPS = { agents: +args.max_agents || Math.max(24, args.tasks.length * 8), codex_tokens: +args.max_codex_tokens || 12_000_000 }
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
  return track(await agent(p, opts))
}

const results = await pipeline(
  args.tasks,
  // Pin: capture pre-run git state so post-verify can separate pre-existing
  // dirt (and detect forbidden commits) from the writer's changes.
  async (t) => {
    const p = lint([
      'MODEL: gpt-5.3-codex-spark',
      'EFFORT: low',
      'SANDBOX: read-only',
      'CWD: ' + t.cwd,
      '',
      'Run `git rev-parse HEAD` and `git status --short` in the current directory and output both results verbatim, nothing else.',
    ].join('\n'))
    const pin = gate(await dispatch(p, { agentType: 'codex-worker', label: 'spark:pin:' + t.id, phase: 'Pin' }))
    return { task: t, pin: pin ? pin.split('\n').filter(l => !/^\[codex-/.test(l)).join('\n').trim() : null }
  },
  // Implement: workspace-write, real writer effort
  async (pinned, t) => {
    const p = lint([
      'EFFORT: ' + (t.effort || 'high'),
      'SANDBOX: workspace-write',
      'CWD: ' + t.cwd,
      '',
      t.spec,
      '',
      'Do NOT commit, push, deploy, or modify configuration outside this workspace — leave all changes uncommitted in the working tree.',
      'When done, output a <=25-line report: files changed/created (paths), what each does, ' +
      (t.test_cmd ? 'full output summary line of `' + t.test_cmd + '`, ' : '') +
      'and any deviation from the spec with why.',
    ].join('\n'))
    const r = gate(await dispatch(p, { agentType: 'codex-worker', label: 'sol:impl:' + t.id, phase: 'Implement' }))
    const files = r && (r.match(/^\[codex-files-written: (\d+)\]/m) || [])[1]
    return { task: t, pin: pinned.pin, report: r, files_written: files ? +files : null }
  },
  // Post-verify: mechanical, read-only, evidence-required (never trust the writer's claims)
  async (impl, t) => {
    if (!impl.report) return { ...impl, verify: { verdict: 'writer-failed', reason: 'no codex session — leg failed or was absorbed' } }
    if (impl.files_written === 0) return { ...impl, verify: { verdict: 'no-op', reason: 'FILES_WRITTEN: 0 — nothing changed on disk' } }
    const p = lint([
      'EFFORT: xhigh',
      'SANDBOX: read-only',
      'CWD: ' + t.cwd,
      '',
      'Mechanically post-verify another agent\'s implementation claim. NEVER trust the report — check the repo state directly.',
      'Spec that was given: ' + t.spec.slice(0, 1500),
      'Writer\'s report: ' + impl.report.slice(0, 1500),
      'If the writer\'s report above is a [codex-final-file: <path>] envelope, read that file for the actual report.',
      impl.pin ? 'Pre-run git state (HEAD + status --short) pinned BEFORE the writer ran:\n' + impl.pin.slice(0, 800) : '',
      'Required checks, each with the actual command + observed output: (1) rg every NEW public symbol for at least one caller outside its own file and its tests; (2) test count before (git stash-free: use git diff to infer) vs after vs the report\'s claims; (3) grep new tests for hedged assertions (`in (`, `or `, truthy-on-union); (4) run one live path' + (t.test_cmd ? ' including `' + t.test_cmd + '`' : '') + (impl.pin ? '; (5) `git rev-parse HEAD` + `git status --short` now vs the pinned state — HEAD must be UNCHANGED (the writer may not commit) and new dirt must match the report\'s file list' : '') + '.',
      'Output ONLY a single minified JSON object on one line, no fences, no prose:',
      '{"verdict":"pass|fail","defects":[{"summary":"...","evidence":"cmd + output"}],"commands_run":[{"cmd":"...","observed":"..."}]}',
    ].filter(Boolean).join('\n'))
    let v = jsonOf(gate(await dispatch(p, { agentType: 'codex-worker', label: 'sol:verify:' + t.id, phase: 'Post-verify' })) || '')
    if (!v) v = jsonOf(gate(await dispatch(p, { agentType: 'codex-worker', label: 'sol:verify:' + t.id + ':retry', phase: 'Post-verify' })) || '')
    if (v && v.codex_file) v = { verdict: 'oversized-output', codex_file: v.codex_file, defects: [], commands_run: [] }
    else if (v && (!Array.isArray(v.commands_run) || !v.commands_run.length)) v = { verdict: 'invalid-no-evidence', defects: [], commands_run: [] }
    return { ...impl, verify: v || { verdict: 'verifier-failed', reason: 'no parseable verdict after retry' } }
  },
)
log('codex spend this run: input=' + usedTokens.input + ' output=' + usedTokens.output + ' (NOT in harness budget)')
if (capPause) log('PAUSED BY CAP: ' + capPause.paused_by + ' — ' + capPause.blocked + ' dispatches blocked after ' + capPause.agents_dispatched + ' agents / ' + capPause.codex_tokens_spent + ' codex tokens')
return { results: results.filter(Boolean), paused_by_cap: capPause, usage: usedTokens }
