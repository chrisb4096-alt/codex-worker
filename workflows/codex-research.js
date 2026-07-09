export const meta = {
  name: 'codex-research',
  description: 'Multi-angle codex research over local repos/docs with synthesis and completeness critique',
  whenToUse: 'Deep LOCAL research (codebases, docs, configs on disk) via codex fan-out. For web research use a codex-worker leg with NETWORK: on + workspace-write scratch (see the contract), not this template. args: {question, cwd: "/abs", angles?: ["..."], gather_effort?: "high", synth_effort?: "xhigh|ultra"}',
  phases: [
    { title: 'Gather', detail: 'one reader per angle' },
    { title: 'Synthesize', detail: 'xhigh merge + completeness critic' },
  ],
}

if (typeof args === 'string') { try { args = JSON.parse(args) } catch {} }
args = args || {}
if (!args.question) throw new Error('args.question required — pass args as an object, not a JSON string')
if (!args.cwd || !String(args.cwd).startsWith('/')) throw new Error('args.cwd (absolute path to research root) required')
const REFFORTS = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra']
for (const k of ['gather_effort', 'synth_effort']) if (args[k] && !REFFORTS.includes(args[k])) throw new Error('args.' + k + ' must be one of ' + REFFORTS.join('|'))
const lint = (p) => { const m = p.match(/undefined\/|: undefined\b|\[object Object\]/); if (m) throw new Error('unresolved variable in prompt: ' + m[0]); return p }
const usedTokens = { input: 0, output: 0, reasoning: 0 }
const codexSessions = []
const runningLegs = []
const SESSION_RE = /^\[codex-session: ((?!missing)[0-9a-fA-F-]{8,})\]/m
const isRunning = (r) => typeof r === 'string' && /^\s*CODEX_RUNNING:/.test(r)
const track = (r, label) => {
  const m = typeof r === 'string' && r.match(/^\[codex-usage: input=(\d+) cached=\d+ output=(\d+)(?: reasoning=(\d+))?/m)
  if (m) { usedTokens.input += +m[1]; usedTokens.output += +m[2]; usedTokens.reasoning += +(m[3] || 0) }
  const s = typeof r === 'string' && r.match(SESSION_RE)
  if (s) codexSessions.push({ label: label || 'leg', session: s[1] })
  if (isRunning(r)) runningLegs.push({ label: label || 'leg', continuation: r.trim() })
  return r
}
const proofReceipt = () => ({
  workflow_proof: {
    status: codexSessions.length ? 'UNVERIFIED' : 'NO_SESSIONS',
    required: codexSessions.length > 0,
    sessions: codexSessions,
    verify_command: codexSessions.length ? '~/.claude/agents/bin/codex-run.sh --verify ' + codexSessions.map(s => s.session).join(',') : null,
    instruction: codexSessions.length ? 'Run verify_command and discard the entire Workflow result if any line says forged.' : null,
  },
  running_legs: runningLegs,
})
// Returns {text, file, session}: exactly one of text/file is non-null. A large
// report (>8KB) rides the [codex-final-file:] envelope — text is null, file is
// that envelope path a downstream leg reads with `cat`. A small report arrives
// inline — text holds it, file is null. We do NOT synthesize the runner's
// per-session archive path here: that archive write is best-effort, so a guessed
// ~/.codex-worker/results/<id>.txt can name a file that was never written and a
// synthesis leg would `cat` a missing path (v3.7 high review). Large reports
// still ride files (embedding them tempts forwarder self-execution and exceeds
// the haiku relay ceiling — 2026-07-07); small inline reports are safe to embed.
const prose = (r) => {
  if (!r || typeof r !== 'string') return null
  if (r.trimStart().startsWith('CODEX_ERROR')) return null
  const s = (r.match(SESSION_RE) || [])[1]
  if (!s) return null
  const f = r.match(/^\[codex-final-file: (\S+) bytes=\d+\]/m)
  const text = f ? null : r.split('\n').filter(l => !/^\[codex-/.test(l)).join('\n').trim()
  if (!f && !text) return null   // footers-with-empty-content misfire = failed leg
  return { text, file: f ? f[1] : null, session: s }
}
// Reference a report by its guaranteed handle: the envelope file (read with cat)
// for large reports, or the inline text for small ones — never a guessed path.
const reportRef = (r, i) => r.file
  ? 'REPORT ' + i + ' — read this file with your shell (`cat <path>`, ~ expands; say so if missing): ' + r.file
  : 'REPORT ' + i + ' (inline):\n' + r.text
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
  return track(await agent(p, opts), opts.label)
}
// ultra runs codex's in-leg multi-agent fleet (broad sweeps / big syntheses) —
// pair with LONG. A still-running run returns CODEX_RUNNING (parses null);
// re-dispatching would DUPLICATE it (v3.7 audit), so retry only a clean failure.
const leg = async (effort, task, opts) => {
  const dirs = effort === 'ultra' ? ['EFFORT: ultra', 'LONG: on'] : ['EFFORT: ' + effort]
  const p = lint([...dirs, 'SANDBOX: read-only', 'CWD: ' + args.cwd, '', task].join('\n'))
  const raw1 = await dispatch(p, { agentType: 'codex-worker', ...opts })
  let r = prose(raw1)
  if (!r && !isRunning(raw1)) r = prose(await dispatch(p, { agentType: 'codex-worker', ...opts, label: (opts.label || 'leg') + ':retry' }))
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
  leg(args.gather_effort || 'high', [
    'Research question: ' + args.question,
    'Your angle (report ONLY through this lens): ' + a,
    'Investigate the repo/files under this directory thoroughly (rg, read files, git log as needed).',
    'Return a dense factual report (<=60 lines): findings with file:line references, direct quotes where load-bearing, and an explicit "could not determine" list. No speculation presented as fact.',
  ].join('\n'), { label: 'sol:gather:' + i, phase: 'Gather' })
))).filter(Boolean)
log(reports.length + '/' + angles.length + ' angle reports gathered')
if (runningLegs.length) return { status: 'running', error: 'one or more gather legs are still running — poll the returned continuations; do not re-dispatch or synthesize partial research', angle_reports: reports, paused_by_cap: capPause, usage: usedTokens, ...proofReceipt() }
if (!reports.length) return { error: 'all gather legs failed', paused_by_cap: capPause, usage: usedTokens, ...proofReceipt() }

phase('Synthesize')
// Large reports ride file paths (embedding 4 x 6KB of inline text is the shape
// that breaks the forwarder contract); small reports arrive inline and are safe
// to embed. reportRef() picks the guaranteed handle per report — no guessed path.
const synthesis = await leg(args.synth_effort || 'xhigh', [
  'Synthesize an answer to: ' + args.question,
  'The independent angle reports follow — inline ones are included directly, file ones must be read with your shell (`cat <path>`, ~ expands; if a file is missing, say so rather than guessing). Trust their file:line evidence, reconcile conflicts explicitly:',
  ...reports.map((r, i) => reportRef(r, i)),
  'Return: the answer, key evidence (file:line), open uncertainties, and what would resolve them. <=80 lines.',
].join('\n'), { label: 'sol:synthesize', phase: 'Synthesize' })
if (!synthesis) {
  log('synthesis leg failed twice — returning raw angle reports')
  return { status: runningLegs.length ? 'running' : 'failed', error: runningLegs.length ? 'synthesis is still running — poll the returned continuation' : 'synthesis leg failed', angle_reports: reports, paused_by_cap: capPause, usage: usedTokens, ...proofReceipt() }
}
const critique = await leg('xhigh', [
  'Completeness critic. Question: ' + args.question,
  synthesis.file
    ? 'The proposed synthesis is in the file ' + synthesis.file + ' — read it with your shell (`cat <path>`, ~ expands).'
    : 'The proposed synthesis is below:\n' + synthesis.text,
  'What is missing, unverified, or assumed? Check the repo directly for the 2-3 most load-bearing claims. Return: verified claims (with command+output), gaps worth a follow-up, verdict solid|needs-work. <=30 lines.',
].join('\n'), { label: 'sol:critique', phase: 'Synthesize' })
log('codex spend this run: input=' + usedTokens.input + ' output=' + usedTokens.output + ' (NOT in harness budget)')
if (capPause) log('PAUSED BY CAP: ' + capPause.paused_by + ' — ' + capPause.blocked + ' dispatches blocked after ' + capPause.agents_dispatched + ' agents / ' + capPause.codex_tokens_spent + ' codex tokens')
return {
  status: runningLegs.length ? 'running' : 'complete',
  synthesis: synthesis.text || ('[see file: ' + synthesis.file + ']'),
  synthesis_file: synthesis.file,
  critique: critique ? (critique.text || ('[see file: ' + critique.file + ']')) : null,
  angle_reports: reports.map(r => r.text || ('[see file: ' + r.file + ']')),
  paused_by_cap: capPause,
  usage: usedTokens,
  ...proofReceipt(),
}
