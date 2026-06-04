# harness — CLAUDE.md

**Repo:** [github.com/ZenHive/harness](https://github.com/ZenHive/harness) (public, default branch `development`).

@~/.claude/includes/across-instances.md
@~/.claude/includes/critical-rules.md
@~/.claude/includes/task-prioritization.md
@~/.claude/includes/task-writing.md
@~/.claude/includes/rmap.md
@~/.claude/includes/workflow-philosophy.md
@~/.claude/includes/ex-unit-json.md
@~/.claude/includes/dialyzer-json.md
@~/.claude/includes/code-style.md
@~/.claude/includes/development-commands.md
@~/.claude/includes/development-philosophy.md
@~/.claude/includes/phoenix-setup.md

**rmap is ours.** The `rmap` CLI (the roadmap substrate `roadmap/tasks.toml` uses) is a sibling Rust project we own at `../rmap/` (i.e. `/Users/efries/_DATA/code/rmap/`). If the roadmap workflow needs a CLI change — new field, query, render, or `delegate --to` target — edit it there; don't work around a gap in harness. `~/.claude/includes/rmap.md` is the usage contract; `../rmap/` is the source.

**Situational skills** (no `@`-import — invoke via Skill tool when trigger matches; don't auto-load): `elixir:reach` (PDG/SDG, `mix reach.otp` OTP introspection — see § Reach), `elixir:web-command` (browser/dashboard work), `elixir:agent-economy` (descripex surface), `elixir:elixir-setup` (dep-stack / alias edits).

**AI driver surface (canonical for orchestrators):** @skills/harness-driver/SKILL.md — load when driving harness as a consumer (the primary user). Stable contract for delegation patterns, non-delegatable handling, result interpretation, sharp edges. Any change to public driver surfaces must update it.

## What This Is

`harness` is an OTP-native Elixir engine an **AI orchestrator drives end to end**: pull a task from the rmap roadmap → dispatch to a **headless coding agent** (Claude Code, Cursor, Codex, Grok, Antigravity, Pi) in an isolated git worktree → run the target project's own check stack against the result → report a *verified* outcome. Consumer surfaces: Elixir API (IEx / tidewave / another BEAM process), the Phoenix LiveView dashboard, and an MCP server. It is a long-running OTP node that orchestrates **N registered target projects** (Elixir, Rust, anything with a shell-driven check stack) concurrently.

**Primary user is an AI agent, not a human** — harness is the OTP-native automation of the delegate → verify → repair loop this repo runs by hand via the `cloud-delegation` skills.

**Not a wrapper around one agent.** The `AgentAdapter` behaviour (Task 3) is a deliberately thin contract: *invoke* an agent, *capture its raw output*, declare capabilities — nothing more. **No normalized event model**: the consumer is an AI that reads each agent's raw JSON natively; harness decides "did the job succeed?" from its **own verification stack**, never from the agent's self-reported result.

## Architecture

- **Elixir / OTP, not TypeScript.** harness *is* N concurrent supervised agent runs needing crash isolation, timeouts, retries, observable state. One run = one supervised `gen_statem`; one batch = a `DynamicSupervisor`.
- **Core loop.** rmap task → dispatch to headless agent in isolated worktree → run target's check stack → green ⇒ done, red ⇒ repair-or-report. The verification stack (not the agent) is the grader — implementer/evaluator separation (global `CLAUDE.md` § Evaluator Separation).
- **Thin adapter pattern.** One adapter per agent: invocation + raw capture + capability declaration. Behaviour `Harness.AgentAdapter` — required callbacks `capabilities/0` + `rule_channel/0` + `build_command/1`; `classify_message/2` + `terminate/1` default via `use Harness.AgentAdapter` + defoverridable. `AgentAdapter.invoke/2` does the generic Port spawn. `build_command/1` threads caller-controlled env (`Invocation.env`, set/scrub pairs → Port, Task 25). Harness-owned rules delivered ahead of `build_command/1` by `AgentAdapter.attach_rules/2` (Task 39), dispatching on `c:rule_channel/0`: `:system_prompt_file` (Claude), `:codex_ephemeral_file` (Codex/Pi), `:cursor_ephemeral_file` (Cursor), `:prompt_preamble` (Grok/Antigravity), `:none` (test doubles). Every adapter must pass `Harness.AgentAdapter.ConformanceCase` **unchanged** — a leak gets fixed in the behaviour, not patched in the adapter.
- **No agent-output parsing.** Raw passthrough is simpler *and* more robust — agents ship 40+ releases; a JSON-format change is absorbed by the AI reading the transcript, not by breaking a normalization layer.
- **Path discipline** (global `CLAUDE.md` § Architecture Drives Design): raw-output capture is hot-path-adjacent (allocation-light); run/batch lifecycle is warm-path OTP state; dashboard / MCP is cold-path.
- **Multi-project federation (shipped, v0_5).** `%Harness.Project{}` (Task 46) carries `source` (`{:local, dir}` or `{:github, url}` — Task 47), `check_stacks` (list of declarative `%Harness.CheckStack{}` — Task 44; Elixir + Rust presets, Tasks 44/45), `roadmap_path`, `concurrency_cap`. **Multi-language monorepos** (Task 92): worktree is always repo-root-granular, so each stack has a `workdir` (relative to worktree root); `Harness.Verification.run/2` runs each stack's checks in its own subdir and flattens to one verdict (green iff all green). Single-language = one stack with `workdir: ""`; singular `preset:`/`check_stack:` still works via back-compat. `Harness.ProjectRegistry` GenServer holds them. **Merge-bar reconciliation (Task 97):** a green `:elixir` preset verdict can still be unmergeable under the project's own `mix precommit` (the Task 94 gap: coverage 80 gate vs measured 75.92%). The `:elixir_precommit` preset mirrors that mergeable bar — adds `format --check-formatted`, `compile --warnings-as-errors`, a coverage threshold on `test`, and `doctor --raise` — so a project opts into "verdict ⇒ mergeable" via `preset: {:elixir_precommit, cover_threshold: 80, exclude: [:integration]}`. The harness self-project registers against it; `:elixir` stays the lighter default.
- **Oban = dispatch layer** (Task 48): queue-per-project gives per-project concurrency caps + restart resilience (jobs survive BEAM death in Postgres). `Oban.Plugins.Cron` (Task 51) enables autonomous roadmap polling. Dashboard (Task 50): `Harness.Dashboard.Endpoint` standalone Bandit on **4018** (conditional behind `:dashboard, :enabled` + `Code.ensure_loaded?(Bandit)` so mountable consumers aren't forced into a 2nd HTTP server), Oban Web at `/harness/oban`, MCP at `/harness/mcp`, Tidewave MCP in dev — all on the one port.

## Orchestration Library — Build a Thin Core (settled, Task 2)

Core is textbook OTP (Port per run, `gen_statem` per run, `DynamicSupervisor` for batches). Adopting a niche orchestration lib adds risk, not leverage. Evaluated `opal`, `gen_agent(_ensemble)`, `altar_ai`, `ex_mcp`, and SDKs `claude_code`/`codex_sdk` — **outcome: build thin core, adopt none, uniform Ports.** Full rationale: `docs/orchestration-library-evaluation.md`.

- **None of the orchestration libs spawns/supervises an external OS process** — no Port in any of them; they coordinate *in-process* LLM agents, harness orchestrates *external* headless CLIs. Three of five are single-release 0–4★ packages — do not add as deps.
- **`claude_code` / `codex_sdk` are CLI wrappers**, not native reimplementations — they still spawn the external binary. An SDK's headline value is a normalized event model, which harness's raw-passthrough design deliberately discards. So **uniform Ports for every adapter**, one invocation strategy behind the behaviour.
- **Cold-path surface = dashboard + Oban Web + MCP, all on one Bandit.** Mountable into a consumer Phoenix endpoint (pattern: Oban Web / LiveDashboard / Tidewave) or standalone via supervised Bandit. MCP (`Harness.Dashboard.MCPServer`, on `anubis_mcp`) exposes the descripex-`api()`-annotated driver surface (`Harness.Manifest`) as real MCP JSON-RPC 2.0 over Streamable HTTP at `/harness/mcp`; external non-Elixir consumers point a standard `.mcp.json` at it. `Harness.Chat.Tools` is the single source of truth for both the in-process chat dispatcher (`Harness.Chat.Session`) and the MCP surface — annotate a tool with `api()` and it appears in both. `Harness.Roadmap.list/2` + `next_bundle/1` (tools `roadmap__list`/`roadmap__next_bundle`) let the orchestrator browse a registered project's roadmap as structured data instead of shelling `rmap` into the live checkout (wrong from harness's cwd, broken for `{:github,_}`). `Harness.Playbooks` (`playbooks__list`/`playbooks__get`) layers orchestration recipes as compile-time-embedded `priv/playbooks/*.md`; dashboard surfaces them as chat-prefill buttons.
- **Oban = queue + persistence + cron, NOT a worker engine.** It *wraps* `Harness.Run` gen_statem: `Harness.Run.Worker` (`Oban.Worker`) takes `{project_name, item_id, adapter_module}`, spawns the gen_statem, threads terminal state into Oban's contract (`:ok`/`{:snooze,_}`/`{:cancel,_}`). gen_statem stays load-bearing (runs are minutes-to-hours with rich live state — too heavy for a flat job row).
- **Dispatch retry vs in-run retry — keep separate.** Oban owns dispatch-level persistence/retry (quota/transient → `{:snooze,_}`, persisted row survives restart). The Task-10 retry policy inside `Harness.Run` owns the repair loop after a red verdict. Open-source Oban has no cross-queue global cap; effective ceiling = sum of `project_<name>` queue limits, so pick `concurrency_cap`s that add up to laptop capacity.
- **`Harness.AgentRegistry` is a soft hint, not a contract** (Task 40, option (b)). Unavailability (quota/manual) lives in GenServer state only — no persistence/TTL/replication; restart clears it **by design**. It's a *latency optimization* (skip known-bad adapter at dispatch); *correctness* lives in Oban (`{:snooze,_}` survives restart + quota window). Quota is transient (~5h rolling), so persisting a mark across restart would usually be stale. Bounded cost of a restart-clear: one wasted attempt per previously-marked adapter. Revisit only as option (c) TTL if harness becomes a long-uptime daemon; never option (a) persist-without-TTL. Rationale: `lib/harness/agent_registry.ex` `@moduledoc`.

## Agent Headless Entry Points (domain reference)

| Agent | Headless invocation | Raw output format |
|---|---|---|
| Claude Code | `claude -p` | `--output-format stream-json` |
| Cursor | `cursor-agent -p` | `--output-format stream-json` |
| Codex | `codex exec` | `--json` |
| Grok | `grok -p` / `agent` subcommand | `--output-format streaming-json` |
| Antigravity | `agy -p` | none (plain text) |
| Pi (pi.dev) | `pi -p` | `--mode json` |

All six driven over OTP Ports — uniform, no per-agent SDK. harness captures raw, never parses/normalizes. **Exit code is unreliable**: derive *termination* from Port close + timeout guard; derive *success* from the verification stack — never `$?`, never the agent's self-report.

**Two-axis adapter contract** (don't conflate):
- **Renderable vs executable**: `rmap delegate --to` now renders a native prompt for all six adapters (`claude`/`codex`/`cursor`/`grok`/`antigravity`/`pi`), so each is a first-class `Roadmap.ingest(agent: …)` target dispatched directly on its own adapter — the old non-delegatable two-step is gone. rmap can also render `droid`, but harness has **no Droid adapter**, so `:droid` is rejected at the ingest/dispatch boundary (`{:invalid_agent, :droid}` / `{:unknown_adapter, "droid"}`). Adding an executor is two-sided: an rmap-lib `--to` target (the rmap binary is ours, `../rmap/` — already done for `droid`) **plus** a harness `AgentAdapter` listed in `Roadmap`'s `@valid_agents`.
- **Worktree isolation**: all six shipped adapters declare `worktree_isolation: true`. Antigravity's Task 32 finding is stale as of `agy` 1.0.5: a 2026-06-04 linked-worktree re-test showed `agy` honoring the Port `cwd` with writes isolated to the run worktree. `Harness.Run` trusts this capability and skips the main-checkout pollution snapshot for isolating adapters. Codex's equivalent regression (Task 41) is resolved (`codex exec --cd`).

## Reach Is in the Dep Stack

Core is OTP-dense (supervision trees, per-run `gen_statem`, `DynamicSupervisor` batch layer, independence reasoning for batches). `mix reach.otp` (state-machine analysis, dead replies, missing handlers, supervision topology) and `Reach.independent?` are on-point. Reach is a dev/test dep (`runtime: false`); invoke the `elixir:reach` skill for OTP introspection / static analysis here.

## Status

**ROADMAP.md (rendered from `roadmap/tasks.toml` by `rmap`) is the live source of truth — start every session with `rmap next`.** This is a high-level snapshot, not a changelog; per-task history lives in `tasks.toml` (`implemented` / `delivered_by` / `verified`) and `.remember/`.

- **Bootstrap (hand-built):** Tasks 1–8, 23, 24 — OTP scaffold, `AgentAdapter` behaviour, Claude adapter, worktree lifecycle, rmap ingestion, verification runner, supervised run lifecycle, commit-before-teardown, immediate-EOF stdin.
- **Phases 1–4 (dogfooded):** all 6 adapters (Claude/Codex/Cursor/Grok/Antigravity/Pi), conformance suite (Task 12), resilience bundle (Task 9 batch orchestrator + concurrency cap, Task 10 failure-classified retry, Task 11 autonomous repair loop), caller-controlled env (25), non-delegatable contract (31), harness-owned rule injection (22 → hoisted into behaviour, 39), capability/availability registry (16/40), `StatusView` + `mix harness.status` (18), structured logging + result store (19), `Harness.AuditReview` HIGH-tier cross-agent grader (58). Worktree-isolation regressions filed + resolved (32 Antigravity, 41 Codex).
- **Phase 7 / v0_5 (multi-project + dashboard, hand-built, complete):** CheckStack + Elixir/Rust presets (44/45), `%Harness.Project{}` + `ProjectRegistry` (46), GitHub sources (47), in-repo template (49), Oban dispatch + Postgres persistence (48), `Oban.Plugins.Cron` poller (51), LiveView dashboard + Oban Web on 4018 (50).
- **Phase 9 / v0_7 (chat orchestrator, complete):** `Harness.Manifest` (75), `Harness.Chat.Session` multi-turn tool-call loop + per-session PubSub (76), MCP server on `anubis_mcp` at `/harness/mcp` (79, reworked), `Harness.Chat.Claude` subscription-OAuth `claude -p` backend (82, scrubs `ANTHROPIC_API_KEY`), `ChatLive` + design tokens (78), MCP child-spec/error fixes (83/84). Task 77 (hand-rolled Req/SSE Anthropic client) **deleted as superseded** — violated the "Claude subscription, not API" rule + library-first heuristic; `Session` `:backend` is now required. **Library-first rule reasserted: hand-rolling a protocol/SDK when a battle-tested hex package exists is a planning failure, not minimalism.**
- **In progress (v0_8):** dashboard LiveViews (`Transcript.Parser` + per-agent parsers, Components/Tokens refactor, flat `dispatch__task` tool, run kill button (94), per-stack `workdir` (92), playbook prefill chips, chat Stop/cancel + streaming-indicator lifecycle (95/96), chat persistence + session index (93, `Harness.Chat.Store`)); `RoadmapLive` next. Confirm specifics via `rmap next` — this list drifts.

## Dogfooding — harness Builds harness

From the core loop onward, harness is developed *by* harness. **Once the bootstrap (Tasks 8, 23, 24) is `done`, every remaining pending task is delivered by dispatching it through harness** — ingest the rmap task, run a headless agent in an isolated worktree, grade against the verification stack. Hand-build only what harness cannot yet do for itself. Operational runbook: `docs/dogfooding-workflow.md` (driver script, verdict table, sharp edges). AI driver reference: `skills/harness-driver/SKILL.md` (load-bearing — changes to `AgentAdapter.*` / `Run.Supervisor` / `Batch` / `Roadmap` / Invocation/result shapes must update it).

- **Roadmap = harness's own test corpus.** Every dogfooded task doubles as a live integration test; a task harness fails to deliver is a harness bug, filed via `rmap new`, not worked around by hand-building.
- **Verification stays separate.** Dispatched agent = implementer; harness's check stack = grader. Done = verification green, never the agent's self-report.
- **Repair loop landed (9/10/11).** A red verdict isn't stop-the-line: harness resumes the agent with failing checks fed back, re-grades up to `:max_repair_attempts`. An `rmap next-bundle` can fan out + dogfood unattended under a concurrency cap.
- **Hand-built exceptions:**
  - *Scaffolding that reshapes harness's own runtime* (supervision tree, dep stack, Endpoint) **while the verification stack itself is in flux** — the Phase 7/v0_5 + chat-bundle precedent. A new phase that only adds features on stable surfaces does **not** earn a hand-build window.
  - *Tiny tasks* — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change (no new adapter/behaviour-callback/supervision-tree/verification-stack edit). Dispatching two ~15-LOC fixes burns 2× orchestration tokens for ~zero integration signal. Fail any of (a)/(b)/(c) → dispatch. When in doubt, dispatch.
  - *UI / LiveView / heex / CSS work* — hand-build via tidewave + browser, not headless dispatch (global `CLAUDE.md` § "Hand-Build UI Tasks"). Headless agents idle-timeout with no visual reward signal.
- **Multi-project autonomy (available via 46/48/51):** dogfooding extends from "harness on harness" to N registered projects, each with its own check stack + `roadmap_path`; with cron enabled it runs unattended.
