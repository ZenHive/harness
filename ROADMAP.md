# harness Roadmap

**Vision:** An OTP-native task-execution engine an AI orchestrator drives end to end — it pulls tasks from the rmap roadmap, dispatches each to a headless coding agent (Claude, Codex, Cursor, Grok, Antigravity, Pi) in an isolated worktree, gates the result with a cross-family reviewer AI (which runs the target project's own checks itself and fixes inline), merges approved work, audits landed commits post-merge with a third agent, and reports the reviewer's verdicts back over an agent-shaped surface (Elixir API / LiveView dashboard / MCP tools). The agent-gate workflow — `worktree → implementer AI → reviewer AI → MERGE → audit AI` — is the architecture; judgment lives in agents, harness code is mechanical substrate only ([docs/agent-gate-workflow.md](docs/agent-gate-workflow.md)).

**Task tracking:** This file is rendered by `rmap` from `roadmap/tasks.toml`. Don't hand-edit the task tables inside `<!-- TASKS:BEGIN -->` / `<!-- TASKS:END -->` marker pairs — they're regenerated on every `rmap render`. Edit `roadmap/tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`, then `rmap render`. Prose outside the marker pairs is byte-preserved.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md).

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** 19 — Self-Healing Run Loop (27 of 28 done · 1 in progress)

**Last shipped:** Task 235 — Surface the self-heal recovery facts — KPI view over Task 229's persisted recovery_attempts + recovery token spend (tests the v0_14 hypothesis), Task 250 — Validate model↔resolved-adapter compatibility at dispatch — reject an incompatible pin pre-spawn, not a mid-run crash, Task 261 — Model/agent availability — block unavailable {agent,model} at dispatch + surface available models over MCP, Task 263 — Grok + codex catalog probes return catalog_unavailable — grok needs a bullet-format parse branch, codex needs a JSON-decode branch, Task 264 — Make a run's landed-state a PERSISTED FACT (landed_sha on the run record), written by the lander — kill the fragile rmap+git mergedness recompute, Task 265 — Unify the three model-catalog sources into one operator-editable, advisory resolution (dedupe probe / static / builtin), Task 266 — Routing-brief: one MCP surface joining roster+availability+capability+KPI per {agent,model} (raw facts, no fused score) so the task-writer routes without reading lib/, Task 267 — Replace unconditional dwell Process.sleep with deterministic synchronization in the test suite, Task 268 — Split run_test.exs by describe-group and convert to async: true (per-test state isolation), Task 269 — Convert dashboard/live_test.exs (59 LiveView tests) to async: true, Task 270 — Convert oban_dispatch_test.exs to async: true, or document why it must stay serial on 2026-06-12

**Up next:** Task 174 — Live-agent E2E smoke test: one real headless agent CLI through the full pipeline, :integration/:live_agent tagged [D:3/B:5/U:4 → Eff:1.5] 🚀
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
> 21 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-4-multi-agent-quota-fail-over).
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
| Task 21 | 🔶 | 🎁 **deferred** · ACP transport adapter [D:7/B:5/U:3 → Eff:0.57] ⚠️ ⛔ Deferred by subscription-auth blocker: revisit only when an ACP backend preserves Claude subscription OAuth, or API-billing dispatch is deliberately accepted for a specific workload. |
| Task 80 | ⛔ | 🎁 **deferred** · Harness.Dashboard.RoadmapLive — multi-project rmap-next browser with 1-click dispatch [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 81 | ✅ | 🎁 **dashboard-chrome** · Harness.Dashboard.CompareLive — A/B agent-evaluation view [D:3/B:4/U:3 → Eff:1.17] 📋 |
| Task 97 | ✅ | 🎁 **deferred** · Reconcile harness verification stack vs project mix precommit [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 140 | ✅ | 🎁 **deferred** · Chat session store: behaviour seam + Postgres backend [D:3/B:2/U:2 → Eff:0.67] ⚠️ |
| Task 141 | ✅ | 🎁 **deferred** · Persist runtime ProjectRegistry registrations to Postgres [D:2/B:2/U:2 → Eff:1.0] 📋 |
| Task 142 | ⛔ | 🎁 **deferred** · Consolidate agent/cron settings term files into a Postgres key-value store [D:2/B:1/U:1 → Eff:0.5] ⚠️ |
| Task 184 | ✅ | 🎁 **deferred** · Expand the descripex/MCP orchestrator surface (inventory first, then read/observe, then a deliberate write subset) [D:3/B:7/U:5 → Eff:2.0] 🎯 |
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
> 4 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-8-closeout-release-readiness).
<!-- TASKS:END -->
