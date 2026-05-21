# harness — CLAUDE.md

@~/.claude/includes/across-instances.md
@~/.claude/includes/critical-rules.md
@~/.claude/includes/worktree-workflow.md
@~/.claude/includes/task-prioritization.md
@~/.claude/includes/task-writing.md
@~/.claude/includes/rmap.md
@~/.claude/includes/workflow-philosophy.md
@~/.claude/includes/web-command.md
@~/.claude/includes/elixir-setup.md
@~/.claude/includes/ex-unit-json.md
@~/.claude/includes/dialyzer-json.md
@~/.claude/includes/code-style.md
@~/.claude/includes/development-commands.md
@~/.claude/includes/development-philosophy.md
@~/.claude/includes/agent-economy.md
@~/.claude/includes/reach.md

## What This Is

`harness` is an OTP-native Elixir engine an **AI orchestrator drives end to end**: it pulls a task from the rmap roadmap, dispatches it to a **headless coding agent** — Claude Code, Cursor, Codex, Grok — running in an isolated git worktree, runs the target project's own check stack against the result, and reports a *verified* outcome back over an agent-shaped surface (MCP tools / JSON CLI).

The primary user is an AI agent, not a human — harness is the OTP-native automation of the delegate → verify → repair loop this repo already runs by hand via the `cloud-delegation` skills.

It is not a wrapper around one agent. The `AgentAdapter` behaviour (Phase 1, Task 3) is the contract, but a deliberately thin one — it *invokes* an agent and *captures its raw output*, nothing more. There is **no normalized event model**: the consumer is an AI that reads each agent's raw JSON natively, and harness decides "did the job succeed?" from its **own verification stack**, never from the agent's self-reported result.

## Architecture

- **Elixir / OTP, not TypeScript.** The harness *is* N concurrent supervised agent runs that need crash isolation, timeouts, retries, and observable state — exactly what OTP provides. One run = one supervised `gen_statem`; one batch = a `DynamicSupervisor`. Building in TS would mean re-implementing supervision by hand.
- **The core loop.** rmap task in → dispatch to a headless agent in an isolated worktree → run the target project's check stack against the result → green ⇒ done, red ⇒ report (later: feed failures back and repair). The verification stack — not the agent — is the grader, which keeps implementer and evaluator separate (global `CLAUDE.md` § Evaluator Separation).
- **Thin adapter pattern.** One adapter per agent — invocation + raw capture + a capability declaration, nothing else. The behaviour is `Harness.AgentAdapter`: four callbacks (`capabilities/0`, `build_command/1`, `classify_message/2`, `terminate/1`), with `AgentAdapter.invoke/2` doing the generic Port spawn. Adapters shell out to each agent's headless mode over uniform OTP Ports — no per-agent SDK (see § "Orchestration Library" for why). Every adapter must pass the shared conformance suite (Task 12) *unchanged* — a leak gets fixed in the behaviour, not patched around in the adapter.
- **No agent-output parsing.** Raw passthrough is simpler *and* more robust: each agent ships 40+ releases, so a JSON-format change is absorbed by the AI reading the transcript, not by breaking a harness normalization layer.
- **Path discipline** (see global `CLAUDE.md` § Architecture Drives Design): raw-output capture is hot-path-adjacent — keep it allocation-light; run/batch lifecycle is warm-path OTP state; the MCP/CLI surface is cold-path.

## Orchestration Library — Build a Thin Core (settled, Phase 1 Task 2)

With the normalized event model cut, the harness core is textbook OTP — a Port per run, a `gen_statem` per run, a `DynamicSupervisor` for batches. Adopting a niche orchestration library to provide that adds risk, not leverage. Task 2 evaluated the candidates (`opal`, `gen_agent` + `gen_agent_ensemble`, `altar_ai`, `ex_mcp`) and the per-agent SDKs (`claude_code`, `codex_sdk`) — outcome **build thin core, adopt none, uniform Ports**. Full rationale + borrowed design ideas: `docs/orchestration-library-evaluation.md`.

- **None of the four orchestration libraries spawns or supervises an external OS process** — there is no Port in any of them. They *implement* or *coordinate* in-process LLM agents; harness *orchestrates external* headless CLIs. Orthogonal problem. Three of the five candidates are single-release, 0–4-star packages — niche, low-download, **do not add any as a dependency** (global `CLAUDE.md` § "Verify External Code Reviews for Correctness").
- **`claude_code` and `codex_sdk` are both CLI wrappers**, not native reimplementations — they still require (`codex`) or auto-install + spawn (`claude`) the external binary. An SDK's headline contribution is a normalized event model over the agent's output; harness's raw-passthrough design (§ "No agent-output parsing") deliberately discards exactly that, and OTP Ports already spawn the binary with the termination + idle-stream signals harness needs. So **uniform Ports for every adapter** — one invocation strategy behind the behaviour, not two.
- **Cold-path MCP surface: hand-roll the JSON-RPC endpoint, not `ex_mcp`.** `descripex` (already in the dep stack) generates the tool list via `Descripex.MCP.tools/1`; what remains is only the transport/handshake half — a bounded JSON-RPC-over-stdio-or-Plug endpoint, cheaper to own than to version-track a dep on a consumer-facing surface.

## Agent Headless Entry Points (domain reference)

| Agent | Headless invocation | Raw output format |
|---|---|---|
| Claude Code | `claude -p` | `--output-format stream-json` |
| Cursor | `cursor-agent -p` | `--output-format stream-json` |
| Codex | `codex exec` | `--json` |
| Grok | `grok -p` / the `agent` subcommand | `--output-format streaming-json` |

All four are driven over OTP Ports — uniform invocation strategy, no per-agent SDK (see § "Orchestration Library").

harness captures these **raw** and passes them through — it does not parse or normalize them. Known gotcha: the headless **exit code is unreliable**. Derive *termination* from the process / Port closing plus a timeout guard; derive *success* from harness's own verification stack — never from `$?`, never from the agent's self-reported result.

## Why `reach.md` Is Imported

The harness core is unusually OTP-dense: supervision trees, a per-run `gen_statem`/GenServer, a `DynamicSupervisor` batch layer, and independence reasoning when deriving batches. `mix reach.otp` (state-machine analysis, dead replies, missing handlers, supervision topology) and `Reach.independent?` are directly on-point. Reach is a dev/test analysis dependency — `runtime: false`, not shipped.

## Status

Tasks 1–7 are done — OTP scaffold, the `AgentAdapter` behaviour, the Claude Code adapter, worktree-per-job lifecycle, rmap task ingestion, and the verification runner. Task 8 — the supervised single-task run lifecycle — is in progress; it is the **last hand-built task** (see § Dogfooding below). `ROADMAP.md` (rendered from `roadmap/tasks.toml` by `rmap`) is the source of truth for what to build next: start with `rmap next`.

## Dogfooding — harness Builds harness

From the core loop onward, harness is developed *by* harness. Task 8 (the supervised single-task run lifecycle) is the bootstrap; it and everything before it are hand-built in a Claude Code session. **Once Task 8 is `done`, every remaining pending task is delivered by dispatching it through harness itself** — harness ingests the rmap task, runs a headless agent in an isolated worktree, and grades the result against the verification stack. Do not hand-build a post-Task-8 task in a Claude Code session; hand-build only what harness cannot yet do for itself.

- **Cutover is Task 8, derivable from rmap.** If `rmap show 8` is `done`, the next `rmap next` task is a dogfood candidate — drive it via harness, don't implement it directly.
- **Supervised until Task 11.** Before the autonomous repair loop (Task 11) lands, dogfooding is supervised: harness dispatches and verifies, a human reads any red verdict and re-dispatches. After Task 11, point harness at an `rmap next-bundle` and let it run unattended.
- **The roadmap is harness's own test corpus.** Every dogfooded task doubles as a live integration test — a task harness fails to deliver is a harness bug, filed via `rmap new`, not worked around by falling back to hand-building.
- **Verification stays separate.** The dispatched agent is the implementer; harness's own check stack is the grader (global `CLAUDE.md` § Evaluator Separation). A dogfooded task is done when the verification stack is green — never on the agent's self-reported result.
