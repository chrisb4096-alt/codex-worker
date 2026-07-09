export const meta = {
  name: 'codex-research',
  description: 'Multi-angle codex research over local repos/docs with synthesis and completeness critique',
  whenToUse: 'Deep LOCAL research (codebases, docs, configs on disk) via codex fan-out. NOT for web research (codex read-only sandbox has no network) — use the deep-research skill for that. args: {question, cwd: "/abs", angles?: ["..."]}',
  phases: [
    { title: 'Gather', detail: 'one reader per angle' },
    { title: 'Synthesize', detail: 'xhigh merge + completeness critic' },
  ],
}

if (typeof args === 'string') { try { args = JSON.parse(args) } catch {} }
args = args || {}
if (!args.question) throw new Error('args.question required — pass args as an object, not a JSON string')
if (!args.cwd || !String(args.cwd).startsWith('/')) throw new Error('args.cwd (absolute path to research root) required')
const lint = (p) => { const m = p.match(/undefined\/|: undefined\b|\[object Object\]/); if (m) throw new Error('unresolved variable in prompt: ' + m[0]); return p }
const usedTokens = { input: 0, output: 0, reasoning: 0 }
const track = (r) => {
  const m = typeof r === 'string' && r.match(/^\[codex-usage: input=(\d+) cached=\d+ output=(\d+)(?: reasoning=(\d+))?/m)
  if (m) { usedTokens.input += +m[1]; usedTokens.output += +m[2]; usedTokens.reasoning += +(m[3] || 0) }
  return r
}
// Returns {text, file, session}: text is the footer-stripped content (null if
// it rode the file relay), file is ALWAYS readable by a downstream codex leg —
// the [codex-final-file:] envelope path, or the runner's per-session archive
// (~/.codex-worker/results/<session>.txt, written on every ok run). Passing
// file paths between legs instead of embedding report text keeps wrapper
// prompts small (large embedded payloads tempt forwarders into self-execution
// and large outputs exceed the haiku relay ceiling — 2026-07-07 incident).
const prose = (r) => {
  if (!r || typeof r !== 'string') return null
  if (r.trimStart().startsWith('CODEX_ERROR')) return null
  const s = (r.match(/^\[codex-session: (?!missing)(\S+)\]/m) || [])[1]
  if (!s) return null
  const f = r.match(/^\[codex-final-file: (\S+) bytes=\d+\]/m)
  const text = f ? null : r.split('\n').filter(l => !/^\[codex-/.test(l)).join('\n').trim()
  if (!f && !text) return null   // footers-with-empty-content misfire = failed leg
  return { text, file: f ? f[1] : '~/.codex-worker/results/' + s + '.txt', session: s }
}
// Spend caps (ops-readiness 2026-07-08): hard per-run ceilings so a runaway
// fan-out pauses with a receipt instead of spending silently. Override per run
// via args.max_agents / args.max_codex_tokens. Complements the harness
// `budget` global, which meters only Claude-side output tokens.
const CAPS = { agents: +args.max_agents || 16, codex_tokens: +args.max_codex_tokens || 5_000_000 }
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
const leg = async (effort, task, opts) => {
  const p = lint(['EFFORT: ' + effort, 'SANDBOX: read-only', 'CWD: ' + args.cwd, '', task].join('\n'))
  let r = prose(await dispatch(p, { agentType: 'codex-worker', ...opts }))
  if (!r) r = prose(await dispatch(p, { agentType: 'codex-worker', ...opts, label: (opts.label || 'leg') + ':retry' }))
  return r
}

const angles = (args.angles && args.angles.length) ? args.angles : [
  'current implementation and code paths relevant to the question',
  'configuration, deployment, and operational state on disk',
  'history: git log, docs, comments explaining why things are the way they are',
  'edge cases, known issues, TODOs, and failure handling related to the question',
]

phase('Gather')
const reports = (await parallel(angles.map((a, i) => () =>
  leg('high', [
    'Research question: ' + args.question,
    'Your angle (report ONLY through this lens): ' + a,
    'Investigate the repo/files under this directory thoroughly (rg, read files, git log as needed).',
    'Return a dense factual report (<=60 lines): findings with file:line references, direct quotes where load-bearing, and an explicit "could not determine" list. No speculation presented as fact.',
  ].join('\n'), { label: 'sol:gather:' + i, phase: 'Gather' })
))).filter(Boolean)
log(reports.length + '/' + angles.length + ' angle reports gathered')
if (!reports.length) return { error: 'all gather legs failed', paused_by_cap: capPause, usage: usedTokens }

phase('Synthesize')
// Reports are passed as FILE PATHS, never embedded: 4 x 6KB of inline report
// text is exactly the prompt shape that breaks the forwarder contract.
const synthesis = await leg('xhigh', [
  'Synthesize an answer to: ' + args.question,
  'The independent angle reports are in these files — read each one with your shell (`cat <path>`, ~ expands; if one is missing, say so rather than guessing). Trust their file:line evidence, reconcile conflicts explicitly:',
  ...reports.map((r, i) => 'REPORT ' + i + ': ' + r.file),
  'Return: the answer, key evidence (file:line), open uncertainties, and what would resolve them. <=80 lines.',
].join('\n'), { label: 'sol:synthesize', phase: 'Synthesize' })
if (!synthesis) {
  log('synthesis leg failed twice — returning raw angle reports')
  return { error: 'synthesis leg failed', angle_reports: reports, paused_by_cap: capPause, usage: usedTokens }
}
const critique = await leg('xhigh', [
  'Completeness critic. Question: ' + args.question,
  'The proposed synthesis is in the file ' + synthesis.file + ' — read it with your shell (`cat <path>`, ~ expands).',
  'What is missing, unverified, or assumed? Check the repo directly for the 2-3 most load-bearing claims. Return: verified claims (with command+output), gaps worth a follow-up, verdict solid|needs-work. <=30 lines.',
].join('\n'), { label: 'sol:critique', phase: 'Synthesize' })
log('codex spend this run: input=' + usedTokens.input + ' output=' + usedTokens.output + ' (NOT in harness budget)')
if (capPause) log('PAUSED BY CAP: ' + capPause.paused_by + ' — ' + capPause.blocked + ' dispatches blocked after ' + capPause.agents_dispatched + ' agents / ' + capPause.codex_tokens_spent + ' codex tokens')
return {
  synthesis: synthesis.text || ('[see file: ' + synthesis.file + ']'),
  synthesis_file: synthesis.file,
  critique: critique ? (critique.text || ('[see file: ' + critique.file + ']')) : null,
  angle_reports: reports.map(r => r.text || ('[see file: ' + r.file + ']')),
  paused_by_cap: capPause,
  usage: usedTokens,
}
