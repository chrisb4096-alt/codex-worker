# Codex direct dispatch — the default mode (macOS and any single host)

This is the **default way to run Claude-orchestrates-Codex**: the Claude Code
main loop dispatches `codex exec` directly from Bash. No subagent forwarder, no
runner script, no enforcement hooks, no install step — if you have Claude Code
and the Codex CLI on the same machine, you already have everything this
document needs.

The runner/forwarder/gate machinery that fills the rest of this repo
(`agents/`, `hooks/`, `install.sh`) is the **alternative** mode, built for a
different trust boundary: a fleet of Linux boxes where legs execute inside a
thin, untrusted small-model forwarder that must be mechanically policed. If
that's not your situation — and on a personal Mac it almost never is — start
here and ignore the rest.

Drop this file somewhere your sessions read (e.g. `~/codex-mac.md`) and add a
pointer line to your `~/.claude/CLAUDE.md`:

```
- Codex work on this machine is direct-dispatch `codex exec` from the main
  loop. Model + effort routing lives in ~/codex-mac.md; read it before
  dispatching or routing a Codex leg.
```

## 1. Doctrine — no runner, forwarder, or gates

In the fleet model, a Codex task flows `orchestrator → codex-worker (small-model
forwarder) → codex-run.sh`, wrapped in PreToolUse/SubagentStop gates and
`[codex-session:]` proof footers. **None of that is needed here.** The gates
exist to police an *untrusted forwarder* — to stop it silently downgrading the
work to its own small model, or authoring the request it claims to forward.
That trust boundary is not present when:

- The orchestrator **is** the Claude main loop (your session). It writes its
  own dispatch and reads its own results — there is no second agent to
  distrust, so there is nothing for a gate to enforce.
- The dispatch primitive is **`codex exec` run directly from Bash** with native
  flags. No runner, no directive grammar (`EFFORT:`/`SANDBOX:`/`CWD:`), no
  error envelopes, no footers.
- Proof-of-execution is trivial: the orchestrator ran the command and holds the
  real stdout/exit in its own tool result. Forged-footer defenses are moot.

What still transfers from the fleet doctrine (it is model behavior, not runner
mechanics): the **routing** guidance below, the **review = candidates-not-
verdicts / verify = one bounded refutation pass** discipline, the
**cross-vendor verification** invariant, and **task-text hygiene** (short
prompts; GPT-5.6 favors terse task text and can *drop required content* if you
pad it with "be concise").

Concurrency ceiling: **≤4 concurrent `codex exec` legs**. Fan out with the
Claude Agent/Workflow tools or background Bash; keep each leg's request
self-contained.

## 2. Canonical `codex exec` shapes (codex-cli 0.144.x)

Reasoning effort is a config override, not a flag: `-c model_reasoning_effort=…`.
Capture **both streams** (`2>&1`) — diagnostics ride stderr.

**Where the files live — resolve this before choosing `-C`.** The dispatch
primitive edits a **local** worktree. If your code roots live on another host,
a literal local leg pointed at an absent path has nothing to edit. Decide
first:

- **Already local, or a small subtree** (≲ tens of MB) → `rsync` the subtree
  local, run legs here, `rsync` back **after review**. Guard the sync-back:
  the remote tree may be dirty or have its own history — reconcile, never
  blind-overwrite.
- **Large tree** → **SSH to the host that owns the files and run `codex exec`
  there** — same direct-dispatch doctrine, co-located with the files. Minor
  codex-cli version skew between hosts is normally benign.
- **Read-only facades** (MCP file servers, code-search endpoints) are not
  write paths — good for context-gathering legs, never for implementation.
- **Host-bound tooling can force the surface**: if a leg needs a tool that
  exists on only one machine (a macOS-only design/audit CLI, a GPU), the work
  runs where the tool lives, and the files come to it.

```bash
# Bounded implementation leg (workspace-write, pinned cwd)
codex exec -m gpt-5.6-sol -c model_reasoning_effort=high \
  --sandbox workspace-write -C /abs/existing/worktree --skip-git-repo-check --json \
  -o /abs/scratch/leg-final.txt 2>&1 <<'REQ'
<terse task text — inputs, exact paths, output shape, stop condition>
REQ

# Read-only research / web leg (network on, isolated scratch cwd)
codex exec -m gpt-5.6-sol -c model_reasoning_effort=high \
  --sandbox read-only -C /abs/scratch --json 2>&1 <<'REQ' … REQ

# Continue a prior leg without replaying its transcript (--last picks the most recent)
codex exec resume <session-id> -m … -c model_reasoning_effort=… --json 2>&1 <<'REQ' … REQ
```

- `-o/--output-last-message <FILE>` exports the final message cleanly — point
  it at scratch, never at a file the leg writes. **`-o` captures the final
  message, so never pair it with "keep your reply short"** — the summary
  becomes the deliverable (measured failure mode: 13/13 legs obeyed the
  instruction and the real deliverables landed in self-chosen filenames).
  With `-o`, instruct *"your final message must BE the complete deliverable;
  do not summarize."* When you want file + summary, have the leg write the
  file itself under workspace-write and make the final message the summary
  (no `-o`). `--output-schema <FILE>` forces the final JSON shape when you
  post-process mechanically.
- **`--json` carries the full deliverable twice on stdout** (`agent_message`
  events + `item.completed`), so long legs can overflow an orchestrator's
  inline tool-result limit (measured: a research leg's stream blew a 64KB
  cap). When only the `-o` deliverable is needed, capture the stream to a side
  file — `> /abs/scratch/leg-stream.jsonl 2>&1` — and read the `-o` file; keep
  the stream file for forensics. `codex exec` also has **no built-in timing**:
  wrap the dispatch in `date` stamps when wall-clock matters as routing
  evidence.
- Chain legs on **distilled outputs only** (paths, summaries, structured
  results) — never by replaying a prior leg's transcript into the next prompt.
- Direct dispatch does not broaden sandbox/CWD/network authority: pin the
  narrowest `--sandbox` and an existing `-C` cwd; typos must fail, not `mkdir`.
- **Logged-in web flows stay orchestrator-side** (your own browser automation:
  CDP/Playwright against a real profile). Codex Computer Use's in-app browser
  cannot do logins — never route a logged-in flow to it.

## 3. Evidence base (dated; verify before treating as canon)

Routing below is **derived from** this evidence, not asserted. Numbers are
mid-2026 public benchmarks; re-check when models move.

| Signal | Fable 5 | Opus 4.8 | GPT-5.6 Sol | Source / date |
|---|---|---|---|---|
| Artificial Analysis Intelligence Index (max) | **60 (#1)** | 56 | 59 (#2) | theairankings, 2026-07 |
| SWE-bench Pro (real-world coding correctness) | **80.3%** | 69.2% | 64.6% | theairankings / claude5.ai, 2026-07 |
| TerminalBench 2.1 (agentic terminal) | 83–84% | — | **88.8%** (Ultra 91.9%) | claude5.ai / lushbinary, 2026-07 |
| OSWorld-Verified (computer use) | — | **83.4%** | — | Anthropic, 2026-05/07 |
| BrowseComp (web research) | — | — | **92.2% (#1)** | steel.dev/llm-stats, 2026-07-13 |
| Agents' Last Exam (long-horizon) | 40.5 | — | **53.6 (+13.1)** | theairankings, 2026-07 |
| Frontend/UI design (WebDev Arena; taste) | **#1, 1653 Elo** | lags both | ~tie one-shot, weak fidelity | steel.dev / banani / creatoreconomy, 2026-07 |
| Token efficiency / cost per task | 1× | — | **~⅓** (~$1.04/task) | theairankings, 2026-07 |
| METR reward-hacking (detected) | — | low | **highest of any public model** | METR / OpenAI system card, 2026-07 |

Two operational facts that shape the routing:

- **Subsidy leverage.** A flat-rate Codex subscription yields inference value
  far beyond its sticker price (this repo's README measures the same effect on
  multi-agent reviews). Cost is not the routing axis, but the subsidy is real:
  spend **Codex** on volume, spend **Claude** where correctness/trust is
  load-bearing.
- **Safety-classifier routing.** Claude Code can force the main loop onto
  Opus for safety-classified work (cyber/chem/bio), regardless of your model
  setting. On such work "orchestrator = Fable" may be unreachable; a genuinely
  independent Fable-grade audit must route **off** the Anthropic main loop (to
  a Codex leg). A Fable *subagent* may also be reclassified — don't assume it
  escapes.

**Reading of the evidence:** Fable is the intelligence + coding-correctness
champ; Opus owns computer-use grounding + tool-call reliability; Sol owns
agentic-terminal throughput, web research, long-horizon, and token efficiency —
**but** Sol is only 3rd on SWE-bench Pro and is the single most reward-hacking-
prone public model. On **frontend**, the practitioner consensus (mid-2026) is
that Sol has genuinely closed the gap on *one-shot greenfield* UI — high
aesthetic instinct, thrives on vague briefs, invents smart details — but Fable
still owns **premium polish, design-system fidelity, and taste adjudication**:
Sol card-stuffs, botches remixing an existing interface, and can't reliably
read design tokens from a screenshot. The correct posture is *comparative
advantage, subsidize the volume, and never let the reward-hacker self-certify.*

## 4. Per-role routing (derived)

1. **Orchestration / planning / synthesis / architecture / product framing /
   taste** → **Claude main loop** (Fable when unclassified, else Opus).
   Highest intelligence index, and it is the *visible, trusted, native*
   multi-agent layer. Never cede top-level orchestration to Sol-Ultra (opaque +
   METR-flagged).
2. **High-volume bounded implementation / refactors / test-writing /
   code-gather / mechanical transforms** → **Codex Sol @ high** (subsidized,
   fast, capable). The workhorse — spend the subsidy here. Any leg that
   *self-verifies* ("make the tests pass") gets an independent check (role 5).
3. **Web research / deep browsing / entangled-info gather** → **Codex Sol @
   high, network on**, isolated scratch cwd. Sol's least-contested win
   (BrowseComp #1 + token efficiency).
4. **Long-horizon agentic terminal work** → **Codex Sol @ high** (TerminalBench,
   Agents' Last Exam). Keep legs bounded and checkpoint outputs —
   reward-hacking risk grows with horizon.
5. **Correctness-critical implementation + verification** → split by advantage:
   - Implementation where a silent defect is expensive (security gates,
     migrations, high blast radius) → **Fable 5** (SWE-bench Pro #1); **Opus**
     via main loop when Fable is unreachable.
   - **Verification is the load-bearing role.** Invariant: **the
     reward-hacking model never signs off on its own or another model's "tests
     pass."** Verify **cross-vendor** (Sol implements → Claude verifies;
     Fable/Opus implements → one Codex-Sol cross-vendor leg decorrelates
     errors), and **evidence-first** — run the repro, diff the changed
     symbols, count tests, and **read the changed files on disk** (a cached
     browser/preview can frame a truthful leg as a liar, or a stale render as
     a fix). Mechanical evidence outranks any model's agreement. Keep it to
     **one bounded refutation pass** (candidates-not-verdicts; no
     review-the-review recursion).
6. **Cheap deterministic legs** (lint, format, exact extraction, git-state
   pins) → **Codex Spark/Luna @ low** — subsidy + speed, no reasoning ceiling
   needed.
7. **Frontend / UI design** → split by mode:
   - *Greenfield, from-scratch, vague-brief* screens → **Codex Sol @ high** is
     now competitive *and* subsidized — a legitimate fast first-draft
     generator.
   - *Premium polish, design-system fidelity, remixing an existing interface,
     taste adjudication* → **Fable 5** (WebDev Arena #1). Opus lags both here.
   - Always hand Sol the **explicit design system/tokens up front** (it can't
     read them from a screenshot) and give aesthetic constraints to counter
     its card-stuffing. Pattern: **Fable owns the design system + final taste
     pass; Sol drafts screens against it.** If you have an automated
     frontend-quality/anti-slop detector, run it on every UI leg's output
     regardless of which model drafted it.

Model slugs: `gpt-5.6-sol` (flagship), `gpt-5.6-terra`/`gpt-5.6-luna` (cheaper —
canary on your own workload before adopting), `gpt-5.3-codex-spark` (fast/cheap
deterministic). **Pro variants are barred** on ChatGPT-subscription auth (400;
`model_reasoning_mode` override is silently ignored — not evidence it works).

## 5. Orchestrating Codex from the Claude main loop (practitioner-validated)

The industry orchestrator-worker consensus (mid-2026, Fable-drives-5.6
write-ups), reconciled with lessons from real multi-leg runs:

- **Split by trust and frequency.** The Claude main loop keeps planning,
  decomposition, delegation, review, synthesis, and taste (strong judgment,
  runs seldom); Codex Sol executes well-scoped, high-frequency legs (speed,
  throughput). Reserve the flagship for the agent whose judgment you trust;
  push volume to the subsidized worker (~10× fewer orchestrator calls than
  worker calls is the typical shape).
- **Resolve all ambiguity before handoff.** Workers fail on underspecified
  briefs — the orchestrator absorbs the ambiguity. Each leg's task text is
  self-contained: inputs, exact paths, output shape, stop condition. This is
  also why 5.6 wants *terse* task text: say what's needed, never pad with "be
  concise" (it may drop required content). **Fully extract the target's gate /
  validator / constraint rules before writing the brief** — a wrong fact in
  the handoff propagates into the leg's work; the leg's own gate check is a
  backstop, not a substitute for an accurate brief.
- **Pass only distilled context.** Give the worker the original request + the
  specific intermediate results it needs + hard constraints — never the
  orchestrator's whole transcript (over-passing degrades the worker and leaks
  context). Chain legs on paths/summaries/structured results.
- **Force the output shape.** Specify the format explicitly; use
  `--output-schema` for anything post-processed mechanically. (Sol legs given
  review-flavored tasks drift into Codex's *native* review JSON instead of the
  requested shape — pin it.)
- **Precise acceptance criteria + bounded retry are the reward-hacking
  mitigation.** State exactly what "acceptable" means (format? required info?
  in scope? repro passes?); cap retries at **2–3**, then escalate to the
  orchestrator or human. Vague criteria produce vague reviews — and Sol is
  the model most likely to return confident, plausible cheating.
- **Parallelize workers** (≤4 concurrent); Sol's low latency keeps parallel
  legs from bottlenecking. Pin cheap models (Terra/Luna/Spark) to high-volume
  low-judgment legs. **Give concurrent legs disjoint file ownership** — group
  work so no two legs touch the same file, and keep shared design-system/
  config files orchestrator-owned. A **shared validator used as each leg's own
  stop condition is unreliable under concurrency** (a leg trips on another
  leg's mid-edit, then passes once both join): treat the per-leg gate as
  advisory and run **one authoritative central gate after all legs join**.
- **Design handoff:** Fable defines the system/tokens → Sol drafts screens
  against it → Fable does the final fidelity + taste pass. Never ask Sol to
  match an existing look from a screenshot alone.
- **Research legs: pin the source bar.** Unconstrained, Sol cites summary
  aggregators (YouTube-recap mills) alongside primary sources. Add *"prefer
  primary sources over summary aggregators; cite first-party URLs"* to
  research task text, and treat leg citations as leg-asserted until
  independently verified.
- **Legs are not hermetic to their task text.** codex discovers user-scope
  config from inside a leg — a research leg was observed spontaneously reading
  a local skill under `~/.codex/skills/` and using it as domain grounding.
  Usually benign-to-useful, but never assume a leg saw only its prompt; keep
  secrets out of user-scope skill/config dirs, and account for skill-content
  bleed when interpreting a leg's framing. (Minor stream noise: `web_search`
  `item.started` events emit empty query strings that `item.completed` later
  fills — harmless unless parsing progress live.)

## 6. Effort default & `ultra`

**Default effort: `high`.** A single-host orchestrator dispatches *fewer, more
consequential* legs than a batch fleet, the subscription removes the cost
argument for `medium`, and the intelligence gap matters most on the
unfamiliar, cross-cutting, weakly-tested work you actually hand off.
De-escalate to **`medium`** explicitly for bounded, familiar, strongly-tested
work under real wall-clock/quota pressure. Escalate to **`xhigh`** for hard
root cause, consequential migration, or adversarial verification. **Avoid
`max`** — it overthinks single-agent legs for little gain. (This tracks
OpenAI's "start at medium" guidance only as the explicit *de-escalation* case,
not the default.)

**`ultra`: keep it OFF.** Public TerminalBench shows Sol-Ultra 91.9% vs 88.8%
single-agent — a ~3pt gain — but it buys an **opaque, Sol-native multi-agent
layer from the model METR ranked #1 for reward-hacking**, exactly where you
least want to lose visibility (we observed a real double-launch /
unbounded-token-burn / twin-workspace-write incident from it). You already
have a **superior, visible** multi-agent layer: the Claude main loop's
Agent/Workflow fan-out. Prefer **orchestrator-level fan-out** (≤4 concurrent
`codex exec` legs, each with explicit ownership and a stop condition) over
ceding orchestration to Sol-Ultra. If a single leg genuinely must
sub-orchestrate, write an explicit bounded protocol into its task text (agent
cap ≤4, retry cap, merge rule, one result in the normal shape) rather than
invoking a native multi-agent profile. Re-evaluate only when a local bench
clears **both** the capability *and* the operational-safety concern.

## When you'd want the runner model instead

Adopt the `agents/` + `hooks/` machinery in this repo (via `install.sh`) only
when the trust boundary changes: legs execute through a thin small-model
forwarder you don't fully trust (to save orchestrator tokens at fleet scale),
multiple boxes share the worker surface, or you need mechanical
proof-of-execution and relay archival. Those are real needs — on a shared
Linux fleet — and that model is documented in the README and
`agents/codex-worker.md`. On a personal Mac, direct dispatch is simpler,
stronger, and has fewer failure modes.
