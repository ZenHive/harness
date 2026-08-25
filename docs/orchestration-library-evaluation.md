# Orchestration Library Evaluation — Build vs. Adopt

> Roadmap Task 2 (Phase 1, `contract` bundle). Evaluation only — no code, no
> dependencies added. This document is the durable record of the decision.

## Decision

**Build the thin core. Adopt none of the candidates. Drive every agent over
uniform OTP Ports — no per-agent SDK.**

Two questions were on the table:

1. Do any of `opal`, `gen_agent` (+`gen_agent_ensemble`), `altar_ai`, `ex_mcp`
   offer something the thin OTP core (a `Port` per run, a `gen_statem` per run,
   a `DynamicSupervisor` for batches) genuinely doesn't?
   — **No.** Confirmed `build-thin-core`.
2. Are `claude_code` / `codex_sdk` CLI wrappers or native reimplementations?
   — **Both are CLI wrappers.** Neither removes the external-binary
   dependency. Confirmed `uniform-Ports`.

The harness premise — drive `claude -p` / `cursor-agent -p` / `codex exec` /
`grok -p` as external binaries over Ports, capture their raw JSON unparsed, and
grade with harness's own verification stack — is **orthogonal** to what every
candidate library does. The libraries either *implement* an agent or
*normalize* agent output; harness *orchestrates external* agents and
deliberately discards the normalized event model. There is no overlap to
exploit.

## The orchestration-library candidates

The decisive structural finding: **none of the four spawns or supervises an
external OS process — there is no Port in any of them.** `opal` and `gen_agent`
run the LLM loop *in-process* against provider HTTP APIs; `gen_agent_ensemble`
coordinates *in-process* sub-agents; `altar_ai` is an HTTP API client. Adopting
any of them would mean inverting harness's architecture, not accelerating it.

| Candidate | Hex maturity | What it is | Verdict |
|---|---|---|---|
| `opal` (`scohen/opal`) | v0.1.21, 7 releases, ~238 downloads, 7-dep tree | OTP-native SDK for *building* a coding agent in Elixir — `gen_statem` agent sessions, tools, provider HTTP layer, JSON-RPC surface | **Ignore as dep** — solves the inverse problem (be an agent, not orchestrate external ones) |
| `gen_agent` (`genagent/gen_agent`) | v0.2.0, **1 release**, 0 GitHub stars, ~1 month old | Behaviour + supervision for in-process LLM agents as 2-state `gen_statem`; headline feature is a *normalized cross-backend event model* | **Borrow ideas only** — useful patterns, but 1-release/0-star and its headline feature is exactly what harness cuts |
| `gen_agent_ensemble` (`genagent/gen_agent_ensemble`) | v0.1.0, **1 release**, 0 stars, ~36 downloads | Multi-agent coordination on top of `gen_agent` — Pool/Pipeline/Debate/Consensus strategies | **Ignore** — thin `DynamicSupervisor` wrapper + multi-agent *collaboration* semantics harness doesn't need (its batches are disjoint by construction) |
| `altar_ai` (`nshkrdotcom/altar_ai`) | v0.1.0, **1 release**, 4 stars | Protocol-based unified client over LLM *HTTP APIs* (Gemini/Claude/OpenAI) | **Ignore** — wrong layer entirely (LLM-API client, not process orchestration). Name collisions ("Codex adapter" = the OpenAI API, not `codex exec`) |
| `ex_mcp` (`azmaveth/ex_mcp`) | v0.9.1, 12 releases, ~2.6k downloads (climbing), 14 stars | Full MCP client+server implementation; relevant to harness's cold-path MCP surface, not its core | **Borrow ideas only** — see below |

Maturity independently disqualifies them as dependencies: three of the five are
single-release packages with 0–4 GitHub stars. This is exactly the niche,
low-download package class `CLAUDE.md` § "Verify External Code Reviews" warns
against adopting.

### `ex_mcp` — the one honest second look

`ex_mcp` is the most competent and most on-point candidate, because harness
*does* expose an MCP-tools surface (cold path). The question is whether it
reduces that work. It does not, decisively:

- harness's planned dep stack already includes **`descripex`**, whose
  `Descripex.MCP.tools/1` generates the MCP tool list
  (`%{name:, description:, inputSchema:}`) from `api()` declarations. The
  *tool-definition* half of the MCP surface is already covered by an in-stack
  dependency.
- What remains is only the *transport/handshake* half — a bounded, one-time
  JSON-RPC-over-stdio-or-Plug endpoint. Comparable effort to integrating and
  version-tracking `ex_mcp`, with fewer dependency risks on a consumer-facing
  API surface.

Hand-roll the JSON-RPC endpoint; lean on `descripex` for the schemas.

## The per-agent SDK question — `claude_code` & `codex_sdk`

**Both are CLI wrappers. Recommendation: skip both, use uniform OTP Ports.**

The only finding that would have justified taking the dep — a *native
reimplementation* that drops the external-binary requirement — does not exist:

| SDK | Hex maturity | Wrapper or native? | Proof |
|---|---|---|---|
| `claude_code` (`guess/claude_code`) | v0.36.3, 44 releases, ~7.5k downloads | **CLI wrapper** | `lib/claude_code/adapter/port.ex:447` — `Port.open({:spawn_executable, exe_path}, …)` spawning the resolved `claude` binary. README: *"Bundled CLI binary, auto-installed on first use."* The SDK auto-downloads `claude`; it still spawns it. |
| `codex_sdk` (`nshkrdotcom/codex_sdk`) | v0.16.1, 29 releases, ~2.4k downloads | **CLI wrapper** | `lib/codex/cli.ex` moduledoc: *"Thin wrapper around the upstream `codex` terminal client."* Agent execution routes through the `cli_subprocess_core` dep (itself v0.1.0) → `ExecutionPlane.Process.Transport` → spawns the local `codex` binary. README: *"You must have the `codex` CLI installed."* |

Both SDKs' core contribution is a **normalized typed event model** over each
CLI's raw JSON output (`ClaudeCode`'s `AssistantMessage`/`ResultMessage`
structs; `Codex.Thread`'s `ThreadStarted`/`ItemCompleted`/`TurnCompleted`
events). That is precisely the abstraction harness's raw-passthrough design
discards — an AI consumer reads the raw transcript natively. OTP Ports already
spawn the binaries with the reliable termination + idle-stream signals harness
needs, and harness's own `gen_statem`-per-run owns lifecycle. Taking either SDK
adds a large competing module surface for zero deployment-story benefit; for
`codex_sdk` it also drags in a heavy, immature transitive tree
(`cli_subprocess_core 0.1.0`, `ExecutionPlane.*`, `bandit`, `websockex`,
`oauth2`, `plug`).

**Caveat for a future re-evaluation:** `codex_sdk` is more than a thin wrapper —
its `app_server/`, `oauth/`, and `realtime/` modules genuinely speak OpenAI
APIs directly. If harness ever needed an OpenAI-API-native (binary-free) Codex
path, `codex_sdk` would be worth re-evaluating. For the headless `codex exec`
orchestration harness actually does, it remains a binary-dependent wrapper and
the recommendation stands.

## Borrowed design ideas (with source)

Recorded so a future instance knows what was deliberately copied vs. invented.

| Idea | Source | Where it applies in harness |
|---|---|---|
| Per-turn **watchdog timeout** expressed as a `gen_statem` state-machine timer | `gen_agent` (watchdog, default 10 min) | Directly serves the domain rule "termination = Port-close + a timeout guard." The per-run `gen_statem` carries a timeout timer. |
| **`tell` / `poll(token)` async pair** alongside a `ask`-style sync call | `gen_agent` / `gen_agent_ensemble` | Shape for the batch surface — `tell` a run, `poll` its raw transcript later. |
| **`Pool` strategy: N workers + FIFO queue + concurrency cap** | `gen_agent_ensemble` Pool strategy | The model for the batch `DynamicSupervisor` — "10 runs, max N concurrent." |
| Per-run **state naming** + a `Collector`/`Emitter`/`Stream` module split for the capture path | `opal` (`Opal.Agent` `gen_statem`; `Opal.Agent.Collector`/`Emitter`/`Stream`) | Naming template for the per-run `gen_statem` states (harness's will be Port-lifecycle-shaped: `spawned/streaming/verifying/done`) and a tidy decomposition for the raw-capture hot path. |
| **`capabilities/0` returning a capability map** (`%{stream: true, …}`), with runtime `supports?/2` | `altar_ai` (`Altar.AI.capabilities/1` / `supports?/2`) | The `AgentAdapter` behaviour's capability-declaration callback. |
| **`deftool` decl-macro + `handle_tool_call/3` dispatch-callback** split; **transport selected at `start_link`** (`:stdio` vs Plug/HTTP), not baked into server logic | `ex_mcp` (`lib/ex_mcp/server.ex`) | The cold-path MCP surface — keep tool *declaration* (via `descripex` `api()`) separate from *execution* dispatch; one tool-dispatch module behind a transport option. |
| Run/turn **lifecycle hooks** (`pre_run`/`post_run` vs `pre_turn`/`post_turn`) — the naming symmetry | `gen_agent` | harness's analog is per-batch vs per-run hooks. |
| Name runs in a **`Registry`** rather than tracking bare PIDs | `gen_agent` (Registry-registered agents) | Standard OTP, but a good reminder for the run layer. |

## Addendum 2026-08-25 — Herdr (terminal multiplexer for coding agents)

> Adjudicated 2026-08-25 (code analysis + full roadmap sweep). Cite this; don't
> re-derive it.

**Herdr** (`herdr` CLI) organizes terminals into workspaces/tabs/panes,
recognizes *interactive* coding agents inside panes (claude/codex/cursor/grok/…),
classifies their lifecycle (`idle`/`working`/`blocked`/`done`/`unknown`), and can
start/prompt/read them (`herdr agent start|prompt|wait|read`, `pane split|run|read`,
`worktree create|open`, `notification show`).

**Verdict: no harness integration — neither as execution backend nor as
observability layer. Herdr's value is entirely operator-side.**

| Considered role | Verdict | Why |
|---|---|---|
| Execution backend (agents in visible panes instead of headless Ports) | **No** | `AgentAdapter.invoke/2` is built on a synchronous OTP Port (`build_command/1` → `{executable, argv, env}`, termination = Port close); a Herdr adapter would replace that with polled pane reads — a second, structurally different execution model, breaking the settled "uniform Ports for every adapter" decision above. Task 23 (done) deliberately gives every agent Port immediate stdin-EOF: the architectural commitment *against* interactive agents. Server-side cron autonomy (Tasks 48/51) has no visible terminal session at all. |
| Mid-flight steering via `agent send-keys`/`prompt` | **No** | Tasks 150/113 (done) explicitly settle boundary-only steering ("there is NO live mid-flight stdin steering"); hold/steer/resume applies operator input at invocation boundaries. |
| Question/approval detection via Herdr's `blocked` state | **No** | Herdr's `blocked` is a UI-dialog classifier — meaning inferred from terminal content, exactly the judgment-in-code class deleted in the agent-gate rebuild (Tasks 153–163). The sanctioned design is Task 399's mechanical `.harness/question.json` → `:held` → steer/resume file check. |
| Run observability (pane transcript reads) | **No** | Duplicates the dashboard surface (Tasks 18, 50, 105, 107, 134, 242/243) and the in-flight `live-run-legibility` bundle (311–315), with worse persistence than `ResultStore`/`dispatch-transcript`. |
| Operator-side tooling (no harness code) | **Yes** | (1) `herdr notification show … --sound done` as a configured witness-notification sink; (2) orchestrator-spawned attach/debug panes tailing `dispatch-transcript` for a run being babysat (see `priv/includes/harness-workflow.md`); (3) `herdr worktree open --path <retained-worktree>` to inspect failed-run worktrees. Operator Claude sessions now run inside Herdr by default, so these are standing conveniences — dispatched agents themselves stay headless and Herdr-free. |

### Known, deliberately unmitigated risk — `HERDR_*` env inheritance

When the harness node (and therefore every dispatched agent Port) is started
from inside a Herdr pane, dispatched agents inherit `HERDR_ENV=1` plus the
caller's `HERDR_WORKSPACE_ID`/`HERDR_TAB_ID`/`HERDR_PANE_ID`. A dispatched
Claude implementer loads user-level CLAUDE.md (which imports the Herdr skill),
so it *could* pass the skill's env gate and issue `herdr` pane/agent commands
against the **operator's live session** — splitting panes, prompting the
operator's agents, reading operator scrollback. The skill's second gate ("act
only when the user explicitly names Herdr") makes this unlikely for normal task
prompts.

**Operator decision 2026-08-25: do NOT scrub — observe first.** The fix, if it
ever fires, is one line at dispatch time: add `"HERDR_ENV" => false` (and the
other `HERDR_*` keys) to the `Invocation.env` scrub pairs (Task 25 mechanism) —
no adapter code change. Symptoms that mean "it fired": unexplained pane
splits/prompts in the operator session during a run, or `herdr` commands in a
dispatched implementer transcript that the task prompt never asked for.

## Acceptance criteria — status

- [x] Each candidate skimmed for whether it offers anything the thin OTP core doesn't — none does.
- [x] Written build-vs-adopt decision with rationale — above.
- [x] Borrowed design ideas recorded with their source — table above.
- [x] `claude_code` / `codex_sdk` determined to be CLI wrappers (not native reimplementations); recommendation is uniform Ports for all four adapters.
