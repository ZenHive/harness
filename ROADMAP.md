# harness Roadmap

**Vision:** An OTP-native task-execution engine an AI orchestrator drives end to end — it pulls tasks from the rmap roadmap, dispatches each to a headless coding agent (Claude, Cursor, Codex, Grok) in an isolated worktree, runs the target project's own check stack against the result, and reports verified outcomes back over an agent-shaped surface (MCP tools / JSON CLI).

**Task tracking:** This file is rendered by `rmap` from `roadmap/tasks.toml`. Don't hand-edit the task tables inside `<!-- TASKS:BEGIN -->` / `<!-- TASKS:END -->` marker pairs — they're regenerated on every `rmap render`. Edit `roadmap/tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`, then `rmap render`. Prose outside the marker pairs is byte-preserved.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md).

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** 4 — Multi-Agent & Quota Fail-over (14 of 19 done · 0 in progress)

**Last shipped:** Task 32 — Antigravity adapter does not isolate to its run worktree, Task 36 — Audit-surfaced: Harness-injected rule files get committed by Worktree.commit, Task 39 — Audit-surfaced: Hoist rule injection into the AgentAdapter behaviour, Task 43 — Dogfood verification reds on pre-existing TODO comments in dispatch base, Task 52 — Add pi.dev headless adapter, Task 55 — Audit-surfaced: BaselineFilter.Credo content-blind matching causes false-pass / false-red on 2026-05-24

**Up next:** Task 53 — Smoke-test pi-via-local-LLM on a low-D rmap task [D:2/B:4/U:4 → Eff:2.0] 🎯
<!-- FOCUS:END -->

---

## Phase 1: Foundation

> The contract before the code. Scaffold the OTP app, confirm a thin OTP core beats adopting an orchestration library, and pin the `AgentAdapter` behaviour — invocation and raw-output capture, no normalized event model.

<!-- TASKS:BEGIN phase=1 -->
> 3 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-1-foundation).
<!-- TASKS:END -->

---

## Phase 2: Core Loop & Contract Proof

> The loop working end to end, then proven against a second agent. The Claude headless adapter, a worktree per job, rmap task ingestion, the verification runner, and the supervised `gen_statem` that drives them to a verdict — then the conformance suite and the Codex adapter, a second implementor that shakes out any Claude-specific leak in the `AgentAdapter` contract before Phase 3's resilience layer couples to it.

<!-- TASKS:BEGIN phase=2 -->
> 10 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-2-core-loop-contract-proof).
<!-- TASKS:END -->

---

## Phase 3: Batch & Resilience

> Concurrent batch fan-out under a `DynamicSupervisor`, a retry policy that classifies transient vs. quota vs. terminal failure, and the autonomous repair loop that feeds red verdicts back to the agent.

<!-- TASKS:BEGIN phase=3 -->
> 11 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-3-batch-resilience).
<!-- TASKS:END -->

---

## Phase 4: Multi-Agent & Quota Fail-over

> Breadth on the proven contract — the Cursor and Grok adapters behind the same behaviour, held to the conformance suite — and a capability + availability registry that fails a job over to another agent when one hits its subscription quota.

<!-- TASKS:BEGIN phase=4 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 13 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Cursor headless adapter [D:6/B:6/U:6 → Eff:1.0] 📋 |
| Task 15 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Grok headless adapter [D:4/B:5/U:5 → Eff:1.25] 📋 |
| Task 16 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Capability + availability registry with quota fail-over [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 22 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Inject a harness-owned rule set into agent invocations [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 23 | ✅ | 🎁 **multi-agent** · 🐛 Give Port-spawned agents an immediate-EOF stdin [D:3/B:3/U:3 → Eff:1.0] 📋 |
| Task 25 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Caller-controlled agent environment in the AgentAdapter contract [D:4/B:5/U:5 → Eff:1.25] 📋 |
| Task 26 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Antigravity headless adapter [D:3/B:4/U:4 → Eff:1.33] 📋 |
| Task 31 | ✅ | 🎁 **multi-agent** · Resolve the rmap-delegate ingest gap for the Grok and Antigravity adapters [D:2/B:3/U:4 → Eff:1.75] 🚀 |
| Task 32 | ✅ | 🎁 **multi-agent** · 🐛 Antigravity adapter does not isolate to its run worktree [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 36 | ✅ | 🎁 **multi-agent** · Audit-surfaced: Harness-injected rule files get committed by Worktree.commit [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 39 | ✅ | 🎁 **multi-agent** · Audit-surfaced: Hoist rule injection into the AgentAdapter behaviour [D:4/B:5/U:5 → Eff:1.25] 📋 |
| Task 40 | ⬜ | 🎁 **multi-agent** · Audit-surfaced: AgentRegistry availability lost on GenServer restart [D:3/B:4/U:4 → Eff:1.33] 📋 |
| Task 41 | ⬜ | 🎁 **multi-agent** · 🐛 Codex adapter — worktree isolation breaks intermittently (cwd ignored, agent edits main checkout) [D:5/B:7/U:7 → Eff:1.4] 📋 |
| Task 43 | ✅ | 🎁 **multi-agent** · 🐛 Dogfood verification reds on pre-existing TODO comments in dispatch base [D:3/B:6/U:7 → Eff:2.17] 🎯 |
| Task 52 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Add pi.dev headless adapter [D:5/B:8/U:7 → Eff:1.5] 🚀 |
| Task 53 `[P]` | ⬜ | 🎁 **multi-agent** · 🚀 **v0_3** · Smoke-test pi-via-local-LLM on a low-D rmap task [D:2/B:4/U:4 → Eff:2.0] 🎯 |
| Task 54 `[P]` | ⬜ | 🎁 **multi-agent** · 🚀 **v0_3** · Cost-aware agent capability declaration (:free vs :metered) [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 55 | ✅ | 🎁 **multi-agent** · 🐛 Audit-surfaced: BaselineFilter.Credo content-blind matching causes false-pass / false-red [D:3/B:7/U:7 → Eff:2.33] 🎯 |
| Task 59 | ⬜ | 🎁 **multi-agent** · Cross-agent grader as a repair-loop move (gated, asymmetric, budgeted) [D:5/B:5/U:4 → Eff:0.9] ⚠️ |
<!-- TASKS:END -->

---

## Phase 5: Surface & Observability

> The agent-shaped entry point — descripex-generated MCP tools + a JSON CLI — plus a human status view and structured run logging, so both the AI orchestrator and the human can see what the fleet is doing.

<!-- TASKS:BEGIN phase=5 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 18 `[P]` | ✅ | 🎁 **surface** · 🚀 **v0_4** · Human status view [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 19 `[P]` | ✅ | 🎁 **surface** · 🚀 **v0_4** · Structured run logging + result persistence [D:5/B:5/U:5 → Eff:1.0] 📋 |
| Task 33 | ⬜ | 🎁 **surface** · Same-task A/B agent-evaluation mode [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 42 | ✅ | 🎁 **surface** · Audit-surfaced: Refresh roadmap focus phase pin after Phase 1 closeout [D:1/B:3/U:4 → Eff:3.5] 🎯 |
| Task 58 | ✅ | 🎁 **surface** · 🚀 **v0_4** · Harness.AuditReview — HIGH-tier audit grader dispatch [D:3/B:7/U:7 → Eff:2.33] 🎯 |
<!-- TASKS:END -->

---

## Phase 6: Deferred

> Parked work — out of scope until the core milestones ship. MCP/JSON-CLI surface (Task 17, reclassified from Phase 5: the Phase 7 dashboard supersedes its Elixir-native use case; revisit only if a non-Elixir consumer needs to drive harness from outside the BEAM), quota-burn telemetry, and an ACP transport adapter. All three speculative, revisited only when there's a concrete reason.

<!-- TASKS:BEGIN phase=6 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 17 | ⬜ | 🎁 **deferred** · Agent-shaped surface — MCP tools + JSON CLI [D:6/B:8/U:8 → Eff:1.33] 📋 |
| Task 20 | ⬜ | 🎁 **deferred** · Run telemetry + quota/cost accounting [D:5/B:3/U:3 → Eff:0.6] ⚠️ |
| Task 21 | ⬜ | 🎁 **deferred** · ACP transport adapter [D:7/B:5/U:3 → Eff:0.57] ⚠️ |
<!-- TASKS:END -->

---

## Phase 7: Multi-Project Federation

> Scoped pivot (milestone v0_5): harness extends from "harness-on-harness" to N registered target projects (Elixir, Rust, anything with a shell-driven check stack). First-class `%Harness.Project{}` registry; declarative `%Harness.CheckStack{}` with per-language presets; Oban-backed dispatch (queue-per-project, restart-resilient); GitHub source cloning; Phoenix LiveView dashboard + embedded Oban Web as the primary cold-path surface; cron-driven autonomous roadmap polling. Hand-built (not dogfooded) for the pivot window — see CLAUDE.md § Dogfooding.

<!-- TASKS:BEGIN phase=7 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 44 | ✅ | 🎁 **multi-project** · 🚀 **v0_5** · Promote check stack to a first-class %Harness.CheckStack{} with a preset library [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 45 | ✅ | 🎁 **multi-project** · 🚀 **v0_5** · First non-Elixir preset: Rust check stack [D:3/B:6/U:6 → Eff:2.0] 🎯 |
| Task 46 | ✅ | 🎁 **multi-project** · 🚀 **v0_5** · %Harness.Project{} struct + in-memory ProjectRegistry; Run takes Project [D:6/B:8/U:9 → Eff:1.42] 📋 |
| Task 47 | ✅ | 🎁 **multi-project** · 🚀 **v0_5** · Harness.Project.Source.Github: clone-and-cache + fetch-before-run [D:5/B:6/U:6 → Eff:1.2] 📋 |
| Task 48 | ✅ | 🎁 **multi-project** · 🚀 **v0_5** · Oban-backed dispatch: queue-per-project + run-state persistence across restart [D:7/B:9/U:8 → Eff:1.21] 📋 |
| Task 49 | ✅ | 🎁 **multi-project** · 🚀 **v0_5** · In-repo <repo>/harness/ subdirectory recipe + template [D:2/B:4/U:4 → Eff:2.0] 🎯 |
| Task 50 | ✅ | 🎁 **dashboard** · 🚀 **v0_5** · Phoenix LiveView dashboard + embedded Oban Web (mountable + standalone) [D:7/B:9/U:8 → Eff:1.21] 📋 |
| Task 51 `[P]` | ✅ | 🎁 **multi-project** · 🚀 **v0_5** · Cron-driven autonomous roadmap polling via Oban.Plugins.Cron [D:3/B:6/U:5 → Eff:1.83] 🚀 |
| Task 60 | ⬜ | 🎁 **multi-project** · 🐛 Harness.Worktree.Isolation false-positive on incidental .claude/ writes during dogfood [D:2/B:6/U:7 → Eff:3.25] 🎯 |
| Task 61 | ⬜ | 🎁 **multi-project** · 🐛 Codex run worktree disappeared mid-run + cross-wrote into a sibling worktree (Wave 1) [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 62 | ⛔ | 🎁 **multi-project** · 🐛 Stale @spec on Harness.Batch.loop_context/8 hid 17 cascade dialyzer warnings (Wave 1) [D:2/B:4/U:5 → Eff:2.25] 🎯 |
<!-- TASKS:END -->
