# harness Roadmap

**Vision:** An OTP-native task-execution engine an AI orchestrator drives end to end — it pulls tasks from the rmap roadmap, dispatches each to a headless coding agent (Claude, Cursor, Codex, Grok) in an isolated worktree, runs the target project's own check stack against the result, and reports verified outcomes back over an agent-shaped surface (MCP tools / JSON CLI).

**Task tracking:** This file is rendered by `rmap` from `roadmap/tasks.toml`. Don't hand-edit the task tables inside `<!-- TASKS:BEGIN -->` / `<!-- TASKS:END -->` marker pairs — they're regenerated on every `rmap render`. Edit `roadmap/tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`, then `rmap render`. Prose outside the marker pairs is byte-preserved.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md).

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** 10 — Dashboard Operator UX (11 of 11 done · 0 in progress)

**Last shipped:** Task 126 — Run change-set view on the run-detail page (live edited-files + settled git diff) on 2026-05-31

**Up next:** Task 130 — rmap: first-class per-task agent/delegate field (stop overloading model) [D:3/B:3/U:3 → Eff:1.0] 📋
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
> 20 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-4-multi-agent-quota-fail-over).
<!-- TASKS:END -->

---

## Phase 5: Surface & Observability

> The agent-shaped entry point — descripex-generated MCP tools + a JSON CLI — plus a human status view and structured run logging, so both the AI orchestrator and the human can see what the fleet is doing.

<!-- TASKS:BEGIN phase=5 -->
> 8 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-5-surface-observability).
<!-- TASKS:END -->

---

## Phase 6: Deferred

> Parked work — out of scope until the core milestones ship. MCP/JSON-CLI surface (Task 17, reclassified from Phase 5: the Phase 7 dashboard supersedes its Elixir-native use case; revisit only if a non-Elixir consumer needs to drive harness from outside the BEAM), quota-burn telemetry, and an ACP transport adapter. All three speculative, revisited only when there's a concrete reason.

<!-- TASKS:BEGIN phase=6 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 17 | ⛔ | 🎁 **deferred** · Agent-shaped surface — MCP tools + JSON CLI [D:6/B:8/U:8 → Eff:1.33] 📋 |
| Task 21 | ⬜ | 🎁 **deferred** · ACP transport adapter [D:7/B:5/U:3 → Eff:0.57] ⚠️ |
| Task 80 | ⛔ | 🎁 **deferred** · Harness.Dashboard.RoadmapLive — multi-project rmap-next browser with 1-click dispatch [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 81 | ✅ | 🎁 **dashboard-chrome** · Harness.Dashboard.CompareLive — A/B agent-evaluation view [D:3/B:4/U:3 → Eff:1.17] 📋 |
| Task 97 | ✅ | 🎁 **deferred** · Reconcile harness verification stack vs project mix precommit [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 140 | ⬜ | 🎁 **deferred** · Chat session store: behaviour seam + Postgres backend [D:3/B:2/U:2 → Eff:0.67] ⚠️ |
| Task 141 | ⬜ | 🎁 **deferred** · Persist runtime ProjectRegistry registrations to Postgres [D:2/B:2/U:2 → Eff:1.0] 📋 |
| Task 142 | ⬜ | 🎁 **deferred** · Consolidate agent/cron settings term files into a Postgres key-value store [D:2/B:1/U:1 → Eff:0.5] ⚠️ |
<!-- TASKS:END -->

---

## Phase 7: Multi-Project Federation

> Scoped pivot (milestone v0_5): harness extends from "harness-on-harness" to N registered target projects (Elixir, Rust, anything with a shell-driven check stack). First-class `%Harness.Project{}` registry; declarative `%Harness.CheckStack{}` with per-language presets; Oban-backed dispatch (queue-per-project, restart-resilient); GitHub source cloning; Phoenix LiveView dashboard + embedded Oban Web as the primary cold-path surface; cron-driven autonomous roadmap polling. Hand-built (not dogfooded) for the pivot window — see CLAUDE.md § Dogfooding.

<!-- TASKS:BEGIN phase=7 -->
> 17 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-7-multi-project-federation).
<!-- TASKS:END -->

---

## Phase 8: Closeout & Release Readiness

> v0.6 stabilization: align roadmap reality, refresh operator docs, prove the README
> and `harness-driver` skill against the live Tidewave/dashboard surface, and keep
> deferred transport ideas out of the normal closeout queue.

<!-- TASKS:BEGIN phase=8 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 71 | ✅ | 🎁 **closeout** · 🚀 **v0_6** · v0.6 closeout: doc + skill refresh, rmap doctor cleanup, Tidewave smoke [D:3/B:8/U:9 → Eff:2.83] 🎯 |
| Task 72 | ✅ | 🎁 **closeout** · 🚀 **v0_6** · Register the harness checkout as a project on boot (dev default) [D:2/B:6/U:8 → Eff:3.5] 🎯 |
| Task 73 | ✅ | 🎁 **closeout** · 🚀 **v0_6** · ResultStore.File.list_run_records skips undecodable term files instead of halting [D:2/B:5/U:7 → Eff:3.0] 🎯 |
| Task 74 | ✅ | 🎁 **closeout** · 🚀 **v0_6** · Document cross-checkout consumer workflow (SKILL.md + README) [D:2/B:7/U:7 → Eff:3.5] 🎯 |
<!-- TASKS:END -->
