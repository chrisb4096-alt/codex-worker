# codex-worker

Run Claude Code's multi-agent workflows on OpenAI Codex (GPT-5.6-sol) workers. Claude stays the orchestrator — planning, fan-out, adjudication — while every subagent leg executes on your Codex subscription instead of your Claude one.

The result, measured on real workloads: a comparable multi-agent code review costs roughly **$1.28 of Claude-side API-equivalent tokens instead of $117** (details and caveats in [Token economics](#token-economics)).

## Start here: direct dispatch (the default)

There are two ways to run Claude-orchestrates-Codex, and for most people — anyone on a personal machine, which usually means a Mac — the right one is the simple one:

**[`codex-mac.md`](codex-mac.md)** — the Claude Code main loop dispatches `codex exec` directly from Bash. **No install step, no hooks, no runner** — if you have Claude Code and the Codex CLI logged in on the same machine, you're done:

```bash
curl -fsSL https://raw.githubusercontent.com/chrisb4096-alt/codex-worker/main/codex-mac.md -o ~/codex-mac.md
```

then add the pointer line it suggests to your `~/.claude/CLAUDE.md` so every session reads it before dispatching Codex work. The document carries everything that actually matters: the canonical `codex exec` shapes, an evidence-derived model/effort routing table (which model for which role, and why), fan-out rules, and the verification discipline that keeps a reward-hacking-prone worker honest.

Everything below this section is the **alternative** mode: the runner/forwarder/gate machinery, built for a different trust boundary — a shared Linux fleet where legs execute inside a thin, untrusted small-model forwarder that must be mechanically policed, so orchestrator tokens are spent on a haiku-class relay instead of the main loop. If that's not your situation, you don't need it; the doctrine section of `codex-mac.md` explains exactly when you would.

## The runner model (the fleet alternative)

Claude Code's `Agent` tool and `Workflow` tool can spawn subagents of a custom type. This repo defines one: `codex-worker`, a deliberately thin forwarder whose only job is to pipe a task to the Codex CLI and relay the answer back verbatim. Around it sit a runner script, four enforcement hooks, and three ready-made workflow templates.

- `agents/codex-worker.md` — the subagent contract (runs on a small, cheap Claude model; it forwards, it never thinks)
- `agents/bin/codex-run.sh` — the runner: launches `codex exec` detached, polls, relays output with proof footers, archives results, re-emits lost relays (`--recover`)
- `hooks/codex-worker-bright-line.py` — PreToolUse gate: a codex-worker leg may only invoke the runner, nothing else
- `hooks/codex-worker-stop-gate.py` — SubagentStop gate: a leg may not finish without proof it actually forwarded
- `hooks/codex-worker-start-context.py` — SubagentStart injector: refreshes the contract in every leg's context before its first turn
- `hooks/workflow-args-gate.py` — PreToolUse gate on the Workflow tool: catches double-encoded args and unguarded scripts at dispatch
- `workflows/` — `codex-review`, `codex-implement-verify`, `codex-research` templates
- `tests/test_gates.py` — 51-case unit matrix for the hooks (stdlib only)

## How it works

```
Claude Code (orchestrator, your best Claude model)
  └─ Workflow / Agent tool spawns agentType: 'codex-worker'
       └─ thin forwarder subagent (haiku-class — the ONLY Claude tokens a leg costs)
            └─ Bash: task text | codex-run.sh --footer --effort high ...
                 └─ detached `codex exec` (GPT-5.6-sol) does the actual work
            ←─ stdout relayed VERBATIM + [codex-session:] [codex-usage:] footers
```

Key design points:

- **The forwarder is not allowed to be smart.** Its prompt says: read the directive lines, build one runner command, return stdout verbatim. Everything else is enforced mechanically (see gates below), because prompts alone were not enough.
- **Detached execution.** The runner launches Codex detached and prints a `CODEX_RUNNING` line with a `--poll` continuation command. Long tasks survive tool-call timeouts; the forwarder just polls until the run resolves.
- **Proof footers.** Every successful relay ends with `[codex-session: <uuid>]` and `[codex-usage: input=N cached=N output=N reasoning=N]`. No footer means Codex never ran — the output is rejected, not trusted.
- **File relay for big outputs.** Small-model relays garble large verbatim payloads. Outputs over 8KB arrive as a `[codex-final-file: <path> bytes=<n>]` envelope instead, and every successful run is archived to `~/.codex-worker/results/<session>.txt` (7-day retention) so a garbled relay is recoverable without re-spending tokens.
- **Symmetrically: never embed more than ~4KB in a worker prompt.** Pass file paths. Big embedded payloads both risk garbling and tempt the forwarder into answering the task itself.

## The failure modes, and the gates that kill them

We ran this in anger for weeks. The forwarder model fails in four characteristic ways, and each gate exists because prompting could not fully prevent one of them:

1. **Self-execution.** The forwarder answers the task itself instead of forwarding — confidently, plausibly, on a model far too small for the work. In our worst incident, 16 of 16 workflow legs did this and the fan-out silently ran on a haiku-class model. Killed by the **bright-line gate** (PreToolUse): inside a codex-worker leg, the Bash command is parsed segment by segment and denied unless the whole call is one of exactly three shapes — the `--parse-request` launch (the runner reads the entire request from stdin, so the forwarder composes no flags of its own), a runner-authored `--poll` continuation, or a `--recover`. Staging idioms and extra flags are denied. Note what this does and does not check: the gate validates the *shape* of the call, not the request body — a PreToolUse hook never sees the orchestrator's original prompt, so it cannot verify the forwarder piped that prompt verbatim. Task-text fidelity is containment by design (the injected contract plus a forwarder with no flag vocabulary and nothing to gain), not a per-call comparison. A forwarder that cannot read files cannot answer questions about them.
2. **Placeholder returns.** The forwarder launches the run, never polls, and returns "the task is still running..." as its final answer. Killed by the **stop gate** (SubagentStop): the final message must carry a non-`missing` session footer, a leading `CODEX_ERROR`, or a StructuredOutput submission that followed a real runner call. A runner invocation earlier in the transcript is not proof. A blocked leg gets one poll-and-recover instruction; a *second* unproven stop is deliberately allowed through (so a gate bug can never wedge a leg forever) but logged as a violation, so this is a one-shot block, not an absolute one — misfire rates stay measurable in the log.
3. **Corrupted dispatch.** Workflow args passed as a JSON-encoded string instead of an object read as `undefined` in the script — silently — and interpolate the literal string `undefined` into every worker prompt. Killed by the **args gate** (PreToolUse on Workflow): genuinely double-encoded args are denied with an explanation the orchestrator can act on, and scripts that read `args.*` without a parse-or-throw guard are denied until they add one.
4. **Stripped relays.** The forwarder keeps the proof footers but drops the body — the result looks authenticated and is empty. Killed by the **stop gate**: a footers-only final message blocks once with the exact recovery command (`codex-run.sh --footer --recover <session>`), which re-emits content + footers deterministically from the runner's archive. No model retyping, no re-run spend.

The gates fail open on malformed input — they must never block valid work — and log one line per decision so you can audit them. A fifth, softer layer runs before any of this: a **SubagentStart injector** puts a compact contract reminder into every leg's context before its first turn, which in practice prevents most violations the other gates would otherwise have to catch (each catch costs a burned turn).

## The contract

A codex-worker task is plain text, optionally opened by directive lines:

- `EFFORT: none|low|medium|high|xhigh|max|ultra` — Codex reasoning effort per role (default high; xhigh for synthesis/debug/adversarial verification; ultra = codex-native multi-agent orchestration inside one leg; low/none for extraction/lint)
- `SANDBOX: read-only|workspace-write` — filesystem access for the Codex run (default read-only)
- `CWD: /abs/path` — repo the task operates on
- `NETWORK: on` — allow network access (web research legs)
- `MODEL: <id>` — override the Codex model (e.g. a faster small model for mechanical legs)
- `SCHEMA: <one-line JSON Schema>` — ask Codex for schema-conforming JSON
- `REVIEW: uncommitted|base=<branch>|commit=<sha>` — Codex's native review harness: it gathers its own diff and returns structured findings
- `OUTPUT_FILE: /abs/path` — write the result to a file instead of relaying it
- `RESUME: <session-uuid>`, `LONG: on`, `MCP: server1,server2` — session continuation, extended timeout, MCP servers

The full contract, including the caller-side parsing snippet and a routing rubric (which model and effort per leg role, and which legs should NOT be codex workers), lives in [`agents/codex-worker.md`](agents/codex-worker.md).

Callers treat worker output as evidence, not authority. The canonical `parseCodex` helper (used by all three bundled workflows) rejects anything without a valid session footer, unwraps file-relay envelopes, and brace-extracts JSON so a stray fence doesn't kill a leg. Failed legs retry once, then surface as failures — never as silently missing data.

## Install (runner model only)

Direct dispatch (the default, above) has **no install step** — this section is for the runner/forwarder model.

```bash
git clone https://github.com/chrisb4096-alt/codex-worker
cd codex-worker && ./install.sh
```

Prerequisites:

- Claude Code (any plan; the orchestrator runs on whatever model your session uses)
- Codex CLI installed and logged in (`codex login`) — a ChatGPT Plus/Pro subscription or OpenAI API key
- `python3` for the hooks

`install.sh` copies `agents/`, `hooks/`, and `workflows/` into `~/.claude/`, then merges four hook entries into `~/.claude/settings.json` (backing up the original):

- PreToolUse, matcher `Workflow` → `workflow-args-gate.py`
- PreToolUse, matcher `Bash` → `codex-worker-bright-line.py`
- SubagentStop → `codex-worker-stop-gate.py`, wired via the agent's frontmatter in `agents/codex-worker.md` (fires on both the Agent and Workflow lanes; v4 — install.sh retires any settings.json entry a pre-v4 install merged)
- SubagentStart, matcher `codex-worker` → `codex-worker-start-context.py`

Then, from any Claude Code session:

```
Use a workflow: run codex-review with args {cwd: "/abs/path/to/repo", scope: "staged"}
```

or spawn a single leg with the Agent tool using `subagent_type: codex-worker`.

## Staying in sync

The contract, runner, hooks, and templates evolve as the upstream system is used (every defect or friction point found in real fan-outs feeds back into them). To keep an installation current:

```bash
cd codex-worker
./install.sh --check     # drift report: OK / DRIFT / MISSING per managed file (exit 2 on drift)
git pull && ./install.sh # update to the latest reviewed state
```

`--check` compares your installed `~/.claude` copies byte-for-byte against the repo, so any agent (Claude Code, a cron job, another orchestrator) can verify or restore parity mechanically. If you want unattended updates, gate them explicitly on a successful pull — `if git pull --ff-only; then ./install.sh; fi` — but the recommended loop is: scheduled `--check` to *detect* drift, human-or-agent review of `git log -p ..origin/main`, then `./install.sh` to adopt.

Provenance, for the cautious (recommended reading before piping anything into your agent config): this repo is published by an automated pipeline that only pushes after a gate passes — secret scan (gitleaks), personal-data/path scan, the 51-case hook test suite, and an adversarial LLM security review of the exact diff (the contract file is a subagent system prompt, so it is reviewed as prompt-injection surface, not just as docs). Each sync commit message carries the receipt: upstream source commit, scan results, and the review session id. `.source-commit` records the upstream commit the tree mirrors; `MANIFEST.sha256` lists the digest of every managed file. None of that replaces your own review — read the diff before updating, like anything else you install into an agent's trust boundary.

## Token economics

The pitch is simple: a multi-agent workflow's cost is dominated by its subagent legs, and this stack moves those legs off your Claude subscription entirely. The Claude-side cost of a codex leg is one haiku-class forwarder that reads a short prompt and relays a result.

Measured on our own workflows (API-equivalent pricing: Haiku 4.5 at $1/$5 per MTok, Fable 5 at $10/$50, cache reads at ~0.1x input price):

- **Without (Claude-native):** a 33-agent code review running every leg on Claude's top model consumed 1.23M uncached input + 37.2M cache-read + 4.5M cache-write + 224K output tokens — roughly **$117 API-equivalent**, all against the Claude subscription. That is ~$3.54 per agent leg.
- **With (codex-worker):** a comparable 18-agent review consumed, on the Claude side, only the haiku forwarders: 2.6M cache-read + 0.6M cache-write + 44K output — roughly **$1.28 API-equivalent**, ~$0.07 per leg. The heavy lifting (9.2M input, 85K output on GPT-5.5, 92% cache-hit) landed on the Codex subscription instead.
- Per-leg, that is a **~50x reduction in Claude-side footprint** (~90x on raw unweighted tokens). On a heavy day we pushed 210 codex runs — 77.5M input tokens (85% cached) and 855K output — which at top-Claude-model API weights is on the order of **$237/day of work displaced** from the Claude subscription.

The honest framing of "one Claude sub + one Codex sub feels like five Claude subs": subscription rate limits aren't published in per-token terms, so nobody can prove a 5x multiplier exactly. What we can measure is the displacement above — with the orchestrator-only pattern, the Claude sub spends tokens exclusively on the part Claude is uniquely good at (planning, taste, adjudication, synthesis), and 30–90x fewer of them per unit of delivered work. Claude subscriptions are also priced aggressively relative to raw API cost, which is exactly why you want to stop spending them on bulk extraction and grep-and-summarize legs that a cheaper-per-unit Codex sub handles at parity.

Two honest caveats:

- You're paying for two subscriptions. The math only wins if you actually run multi-agent workloads; for single-threaded chat-style coding, one sub is fine.
- Codex tokens are invisible to Claude Code's budget tracking. The bundled workflows aggregate `[codex-usage:]` footers and report codex spend per run so it stays visible.

## How this differs from other Claude+Codex setups

Theo (t3.gg) has covered the Claude-vs-Codex subscription economics that motivate this kind of setup, and the community has since produced several Claude-delegates-to-Codex bridges — typically MCP servers or plugins that expose Codex as a tool Claude can call (e.g. MCP-based delegation plugins like `claudecode-codex-subagents`). This stack differs in kind, not just degree:

- **Workers are native subagents, not tool calls.** Because `codex-worker` is an agent type, it composes with Claude Code's Workflow orchestration — `pipeline()`, `parallel()`, judge panels, adversarial verification — with Codex executing every leg. An MCP bridge gives you one delegated call; this gives you Codex fleets under deterministic control flow.
- **Enforcement is mechanical, not prompted.** The central discovery of running this for real: a small forwarder model will eventually ignore its instructions and answer the task itself, and you will not notice, because the answer looks plausible. Hooks — an allowlist before every command and a proof-of-forwarding check after every leg — turn "the forwarder should relay verbatim" from a hope into something a bug has to actively defeat rather than merely coast past. These are containment for an *undisciplined* forwarder, not a boundary against a *malicious* one (the orchestrator can always run Bash itself, and the stop gate fails open on a second stop by design); read them as raising the floor, not as an absolute guarantee.
- **Proof over trust.** Session and usage footers make every leg auditable: which Codex session ran, what it cost, whether it ran at all. Unproven output is *blocked* on its first stop with a recovery instruction — and, because the stop gate fails open on a second stop by design (a gate bug must never wedge a leg forever), a persistent violation is ultimately let through but logged, so misfire rates stay visible rather than silently swallowed. Treat the footers as the audit trail, not as an unbreakable seal.
- **Failure is loud and recoverable.** Detached runs survive timeouts, results are archived to disk before relay, oversized outputs ride files instead of getting garbled, and every error surfaces as a leading `CODEX_ERROR` line rather than as silence.

If you already have a Codex MCP bridge you like, the hooks and the footer contract here are still worth stealing — they solve problems any Claude-orchestrates-Codex setup will eventually hit.

## Building your own version

The architecture transfers to any orchestrator/executor pair. The load-bearing ideas, in order of importance:

1. **Thin forwarder + mechanical enforcement.** Don't ask a small model to be disciplined; make discipline the only path that executes. Allowlist its commands (PreToolUse), verify proof-of-work in its final message (SubagentStop).
2. **Proof footers.** Have the runner stamp session id + token usage on every output. Reject unstamped output. This one convention catches self-execution, empty relays, and crashed runs.
3. **Detach + poll.** Never let the executor's runtime be bounded by the forwarder's tool-call timeout.
4. **Files for anything big.** Small relay models garble large verbatim payloads in both directions. Archive to disk, relay a path.
5. **Fail open in the gates, fail loud in the legs.** A gate bug must never block valid work; a leg failure must never look like an empty-but-successful result.

Read `agents/codex-worker.md` for the contract, then `agents/bin/codex-run.sh` — the runner is a single self-contained script and most of the transferable engineering lives there.

## Security notes

- The hooks never see credentials. The runner DOES stage a copy of `~/.codex/auth.json` into its isolated `CODEX_HOME` directories (`~/.codex-worker/`, mode 0700, and the per-run scratch, also 0700) so isolated runs can authenticate — the copy stays same-user on the same machine, and no credential ever rides a prompt, transcript, footer, or this repo. Deleting `~/.codex-worker/` removes the staged copies.
- Runtime state lands in `~/.codex-worker/` (results archive, usage log, poll state). Treat it as private — results contain your code and task text. Nothing in this repo publishes or transmits it.
- Default sandbox is `read-only`; `workspace-write` and `NETWORK: on` are explicit per-task opt-ins in the prompt, visible in the transcript.
- The bright-line gate is a containment layer for the forwarder, not a security boundary against a malicious orchestrator — the orchestrator can always run Bash itself. Its job is preventing accidental self-execution, not adversaries.

## Tests

```bash
python3 tests/test_gates.py
```

51 cases covering all four hooks as subprocesses with an isolated `$HOME`, exercising the real stdin/stdout hook contract — including regression cases for each production incident above.

## License

MIT — see [LICENSE](LICENSE).
