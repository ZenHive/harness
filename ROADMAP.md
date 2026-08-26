# harness Roadmap

**Vision:** An OTP-native task-execution engine an AI orchestrator drives end to end — it pulls tasks from the rmap roadmap, dispatches each to a headless coding agent (Claude, Codex, Cursor, Grok, Antigravity, Pi) in an isolated worktree, gates the result with a cross-family reviewer AI (which runs the target project's own checks itself and fixes inline), merges approved work, audits landed commits post-merge with a third agent, and reports the reviewer's verdicts back over an agent-shaped surface (Elixir API / LiveView dashboard / MCP tools). The agent-gate workflow — `worktree → implementer AI → reviewer AI → MERGE → audit AI` — is the architecture; judgment lives in agents, harness code is mechanical substrate only ([docs/agent-gate-workflow.md](docs/agent-gate-workflow.md)).

**Task tracking:** This file is rendered by `rmap` from `roadmap/tasks.toml`. Don't hand-edit the task tables inside `<!-- TASKS:BEGIN -->` / `<!-- TASKS:END -->` marker pairs — they're regenerated on every `rmap render`. Edit `roadmap/tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`, then `rmap render`. Prose outside the marker pairs is byte-preserved.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md).

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** 23 — Audit Hardening — findings from the 2026-07-12 project health audit (11 of 27 done · 2 in progress)

**Last shipped:** Task 358 — Bound KPI dashboard fleet-wide aggregate reads on run settlement, Task 361 — Add direct coverage for Harness.Store.EtsScope create/lookup and owner-exit table ownership, Task 389 — Expose roadmap_target_branch on the operator registration surfaces, Task 403 — Make the loopback posture true: Origin/Host guard on /harness/mcp + source-URL validation before git clone, Task 404 — Take the uncached SettingsStore reads and the synchronous CLI catalog probes off the 5s settings tick, Task 405 — Audit discovery filing writes into the operator's live checkout and is never committed, Task 413 — Surface an in-flight audit signal on the fleet count strip, not just the ops panel on 2026-08-25

**Up next:** Task 379 — Durable roadmap writeback silently produced no commit — dispatch-start and post-land transitions both lost [D:4/B:7/U:7 → Eff:1.75] 🚀
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
| Task 13 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Cursor headless adapter [D:6/B:6/U:6 → Eff:1.0?] 📋 |
| Task 15 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Grok headless adapter [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 16 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Capability + availability registry with quota fail-over [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 22 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Inject a harness-owned rule set into agent invocations [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 23 | ✅ | 🎁 **multi-agent** · 🐛 Give Port-spawned agents an immediate-EOF stdin [D:3/B:3/U:3 → Eff:1.0?] 📋 |
| Task 25 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Caller-controlled agent environment in the AgentAdapter contract [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 26 | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Antigravity headless adapter [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 31 | ✅ | 🎁 **multi-agent** · Resolve the rmap-delegate ingest gap for the Grok and Antigravity adapters [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 32 | ✅ | 🎁 **multi-agent** · 🐛 Antigravity adapter does not isolate to its run worktree [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 36 | ✅ | 🎁 **multi-agent** · Audit-surfaced: Harness-injected rule files get committed by Worktree.commit [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 39 | ✅ | 🎁 **multi-agent** · Audit-surfaced: Hoist rule injection into the AgentAdapter behaviour [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 40 | ✅ | 🎁 **multi-agent** · Audit-surfaced: AgentRegistry availability lost on GenServer restart [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 41 | ✅ | 🎁 **multi-agent** · 🐛 Codex adapter — worktree isolation breaks intermittently (cwd ignored, agent edits main checkout) [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 43 | ✅ | 🎁 **multi-agent** · 🐛 Dogfood verification reds on pre-existing TODO comments in dispatch base [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 52 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Add pi.dev headless adapter [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 53 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Smoke-test pi-via-local-LLM on a low-D rmap task [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 54 `[P]` | ✅ | 🎁 **multi-agent** · 🚀 **v0_3** · Cost-aware agent capability declaration (:free vs :metered) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 55 | ✅ | 🎁 **multi-agent** · 🐛 Audit-surfaced: BaselineFilter.Credo content-blind matching causes false-pass / false-red [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 59 | ✅ | 🎁 **multi-agent** · Cross-agent grader as a repair-loop move (gated, asymmetric, budgeted) [D:5/B:5/U:4 → Eff:0.9?] ⚠️ |
| Task 67 | ✅ | 🎁 **multi-agent** · 🐛 Audit-surfaced: Batch.run_pinned settles entire pinned queue on one adapter's pre-dispatch unavailability [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 187 | ✅ | 🎁 **multi-agent** · Flip Antigravity worktree_isolation to true — agy 1.0.5 honors port cwd (Task 32 finding is stale) [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 366 `[P]` | ⬜ | 🎁 **multi-agent** · Add Kimi Code headless adapter + full roster wiring [D:5/B:7/U:6 → Eff:1.3] 📋 |
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
| Task 17 | ⛔ | 🎁 **deferred** · Agent-shaped surface — MCP tools + JSON CLI [D:6/B:8/U:8 → Eff:1.33?] 📋 |
| Task 21 | 🔶 | 🎁 **deferred** · ACP transport adapter [D:7/B:5/U:3 → Eff:0.57?] ⚠️ ⛔ Deferred by subscription-auth blocker: revisit only when an ACP backend preserves Claude subscription OAuth, or API-billing dispatch is deliberately accepted for a specific workload. |
| Task 80 | ⛔ | 🎁 **deferred** · Harness.Dashboard.RoadmapLive — multi-project rmap-next browser with 1-click dispatch [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 81 | ✅ | 🎁 **dashboard-chrome** · Harness.Dashboard.CompareLive — A/B agent-evaluation view [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 97 | ✅ | 🎁 **deferred** · Reconcile harness verification stack vs project mix precommit [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 140 | ✅ | 🎁 **deferred** · Chat session store: behaviour seam + Postgres backend [D:3/B:2/U:2 → Eff:0.67?] ⚠️ |
| Task 141 | ✅ | 🎁 **deferred** · Persist runtime ProjectRegistry registrations to Postgres [D:2/B:2/U:2 → Eff:1.0?] 📋 |
| Task 142 | ⛔ | 🎁 **deferred** · Consolidate agent/cron settings term files into a Postgres key-value store [D:2/B:1/U:1 → Eff:0.5?] ⚠️ |
| Task 184 | ✅ | 🎁 **deferred** · Expand the descripex/MCP orchestrator surface (inventory first, then read/observe, then a deliberate write subset) [D:3/B:7/U:5 → Eff:2.0?] 🎯 |
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

---

## Phase 9: Chat Orchestrator

<!-- TASKS:BEGIN phase=9 -->
> 16 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-9-chat-orchestrator).
<!-- TASKS:END -->

---

## Phase 10: Dashboard Operator UX

<!-- TASKS:BEGIN phase=10 -->
> 16 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-10-dashboard-operator-ux).
<!-- TASKS:END -->

---

## Phase 11: Autonomous Landing

<!-- TASKS:BEGIN phase=11 -->
> 40 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-11-autonomous-landing).
<!-- TASKS:END -->

---

## Phase 12: Workflow Substrate

<!-- TASKS:BEGIN phase=12 -->
> 2 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-12-workflow-substrate).
<!-- TASKS:END -->

---

## Phase 13: Agent KPIs & Capability Routing

<!-- TASKS:BEGIN phase=13 -->
> 20 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-13-agent-kpis-capability-routing).
<!-- TASKS:END -->

---

## Phase 14: Agent Rule Injection & Prompt Provenance

<!-- TASKS:BEGIN phase=14 -->
> 5 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-14-agent-rule-injection-prompt-provenance).
<!-- TASKS:END -->

---

## Phase 15: Reviewer-Pair Lifecycle

<!-- TASKS:BEGIN phase=15 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 161 | ✅ | 🎁 **reviewer-pair** · 🚀 **v0_11** · Reviewer core: :reviewing state — cross-family reviewer agent fixes red worktrees inline [D:6/B:9/U:9 → Eff:1.5?] 🚀 |
| Task 162 | ✅ | 🎁 **reviewer-pair** · 🚀 **v0_11** · Route empty-diff and green-review through the reviewer; collapse semantic gate into review_green [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 163 | ✅ | 🎁 **reviewer-pair** · 🚀 **v0_11** · The deletion pass: remove FailureClass, RepairPrompt, BaselineFilter, baseline verification, quota regexes, repair loop, consulting state, semantic-gate machinery [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 164 | ⛔ | 🎁 **reviewer-pair** · 🚀 **v0_11** · 📝 Reviewer-pair docs + driver surface: SKILL.md, CLAUDE.md, StatusView, dashboard fields [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 168 | ⛔ | 🎁 **reviewer-pair** · Worktree/branch collision wedges Oban retries — clean up retained worktree+branch before a same-run_id re-attempt [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 169 | ⛔ | 🎁 **reviewer-pair** · Agent compile errors surfacing in verification SETUP are misclassified as environment failures — route them to the reviewer [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 173 | ✅ | 🎁 **reviewer-pair** · 🚀 **v0_11** · Deterministic full-pipeline E2E test: roadmap task → Oban dispatch → run → verify → review → land → writeback in one flow [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 174 | ⬜ | 🎁 **reviewer-pair** · Live-agent E2E smoke test: one real headless agent CLI through the full pipeline, :integration/:live_agent tagged [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 179 | ⛔ | 🎁 **reviewer-pair** · SMOKE: add a one-sentence summary line to Harness.LineBuffer @moduledoc [D:1/B:1/U:1 → Eff:1.0?] 📋 |
| Task 183 | ⛔ | 🎁 **agent-gate** · Smoke test (throwaway): add Harness.LineBuffer.empty?/1 predicate + test [D:1/B:1/U:1 → Eff:1.0?] 📋 |
| Task 186 | ✅ | 🎁 **agent-gate** · 🔒 Neuter the push remote in harness-created worktrees so in-run agents can't push/PR past landing_policy [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 188 | ✅ | 🎁 **agent-gate** · 🔒 Scrub GH_TOKEN/GITHUB_TOKEN from in-run env + assess the gh pr create vector (push-neuter follow-up) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
<!-- TASKS:END -->

---

## Phase 16: Agent-Gate Workflow & Post-Merge Audit

<!-- TASKS:BEGIN phase=16 -->
> 31 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-16-agent-gate-workflow-post-merge-audit).
<!-- TASKS:END -->

---

## Phase 17: Settings Consolidation & Resilience

<!-- TASKS:BEGIN phase=17 -->
> 14 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-17-settings-consolidation-resilience).
<!-- TASKS:END -->

---

## Phase 18: Judgment Collapse

<!-- TASKS:BEGIN phase=18 -->
> 10 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-18-judgment-collapse).
<!-- TASKS:END -->

---

## Phase 19: Self-Healing Run Loop

<!-- TASKS:BEGIN phase=19 -->
> 44 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-19-self-healing-run-loop).
<!-- TASKS:END -->

---

## Phase 20: Config Surface — Postgres is the only edit surface

<!-- TASKS:BEGIN phase=20 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 283 | ✅ | 🎁 **config-surface** · ProjectRegistry.upsert/1 — replace-or-insert with live Oban queue scaling (foundational) [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 284 | ✅ | 🎁 **config-surface** · Dashboard: concurrency_cap editor + project register/edit/unregister form (close the last config-surface holes) [D:4/B:5/U:4 → Eff:1.12?] 📋 |
| Task 285 | ✅ | 🎁 **config-surface** · Retire config/dev.local.exs: strip dev.exs, run-to-apply seeds.exs.example, mem-threshold env var, boot guard, docs [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 289 | ✅ | 🎁 **dispatch-economy** · Blocking multi-run await: dispatch-await_runs MCP tool [D:2/B:3/U:2 → Eff:1.25?] 📋 |
| Task 290 | ✅ | 🎁 **dispatch-economy** · Spike: out-of-band push sink so a settled run wakes the orchestrator [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 292 | ✅ | 🎁 **dispatch-economy** · Collision-aware dispatch: serialize ready-set tasks with overlapping write-sets instead of fanning them out [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 293 | ✅ | 🎁 **autolanding** · Lander resolver follow-up: same-function conflicts defeat the auto-resolver; manual reland bypasses it entirely [D:3/B:3/U:2 → Eff:0.83?] ⚠️ |
| Task 294 | ✅ | 🎁 **dispatch-economy** · Settled witness event + FileSink for orchestrator wakeup [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 296 | ✅ | 🎁 **dispatch-economy** · 🐛 MCP transport 30s GenServer.call ceiling defeats every blocking dispatch tool [D:3/B:4/U:2 → Eff:1.0?] 📋 |
| Task 297 | ✅ | 🎁 **autolanding** · 🐛 Lander resolver still fails 5/5 trivial additive CHANGELOG keep-both conflicts post-293; eliminate the additive-file conflict class mechanically [D:3/B:4/U:2 → Eff:1.0?] 📋 |
| Task 299 | ✅ | 🎁 **autolanding** · 🐛 Run gen_statem crashed :undef on Harness.Run.reviewing/3 transcript_chunk path during node restart — reload-race or real gap? [D:3/B:2/U:1 → Eff:0.5?] ⚠️ |
| Task 300 | ✅ | 🎁 **autolanding** · Consolidate @recoverable_code_reload_states (Run + Worker) [D:2/B:2/U:2 → Eff:1.0?] 📋 |
| Task 304 | ✅ | 🎁 **autolanding** · Cron poller: suppress re-dispatch of a task whose adapter is unavailable (no churn loop) [D:3/B:3/U:1 → Eff:0.67?] ⚠️ |
| Task 309 | ✅ | 🎁 **config-surface** · Expose warm_paths on the project-authoring surfaces (MCP register_project + dashboard form) — currently settable only via ProjectRegistry.upsert/1 [D:2/B:5/U:2 → Eff:1.75?] 🚀 |
| Task 310 | ✅ | 🎁 **core-loop** · dispatch-await attach-to-in-flight-run wedges the MCP transport instead of returning the structured :timed_out summary (and poisons subsequent dispatch-status/list_runs calls) [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 316 | ✅ | 🎁 **dispatch-economy** · 🐛 dispatch-bundle ignores per-task assignee — routes whole wave to one global adapter, and doesn't gate depends_on [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 317 | ✅ | 🎁 **reviewer-pair** · Harden the reviewer verdict contract — reject-red-tree rule + structured `checks` claim + `concerns` field in review.json [D:4/B:9/U:7 → Eff:2.0?] 🎯 |
| Task 318 | ✅ | 🎁 **reviewer-pair** · Post-merge cold-build witness — un-warmed audit pass; the audit AI runs the clean build and reports red as an agent-written FACT, red => blocked task + loud notify (never revert) [D:4/B:8/U:5 → Eff:1.62?] 🚀 |
| Task 319 | ✅ | 🎁 **reviewer-pair** · Close two reviewer-gate trust holes from the 2026-06-20 audit: dispatch-reland verdict guard + fake-reviewer artifact can't leak into a real checkout [D:2/B:6/U:4 → Eff:2.5?] 🎯 |
| Task 320 | ✅ | 🎁 **core-loop** · Per-run test-DB isolation — concurrent worktree runs share one test DB and cross-contaminate (the verified root cause of tapakly's recurring 'environmental' red suites) [D:4/B:9/U:6 → Eff:1.88?] 🚀 |
| Task 321 | ✅ | 🎁 **reviewer-pair** · Close the false-green loop: audit records approved-then-found-red as a structured reviewer FACT; surface it for AI-judged reviewer routing (no score formula) [D:4/B:8/U:6 → Eff:1.75?] 🚀 |
| Task 325 | ⛔ | 🎁 **reviewer-pair** · 🐛 Fix post-merge cold-check red for 1a2a52e [D:3/B:8/U:5 → Eff:2.17?] 🎯 |
| Task 344 | ✅ | 🎁 **autolanding** · Land-conflict resolver AI cannot spawn: claude adapter has no configured agent_model [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 351 `[P]` | ✅ | 🎁 **autolanding** · 🐛 TaskIdRewriter misses unquoted integer task ids — collision reassignment silently no-ops for integer-id projects [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 375 | 🔄 | 🎁 **config-surface** · 🚀 **v0_16** · 🐛 Validate optional %Harness.Project{} fields at registration — an uncast concurrency_cap silently kills batch dispatch [D:2/B:6/U:6 → Eff:3.0] 🎯 |
| Task 412 | ⬜ | 🎁 **config-surface** · 🔒 Scope inherited credentials per project — every dispatched agent currently sees every registered project's keys [D:4/B:7/U:6 → Eff:1.62] 🚀 |
<!-- TASKS:END -->

---

## Phase 21: Project Introspection — structural code search over registered projects

<!-- TASKS:BEGIN phase=21 -->
> 6 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-21-project-introspection-structural-code-search-over-registered-projects).
<!-- TASKS:END -->

---

## Phase 22: Live-Run Observability — stop flying blind while an agent works

<!-- TASKS:BEGIN phase=22 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 311 | ✅ | 🎁 **live-run-legibility** · 🚀 **v0_15** · Transcript legibility — kill the content-less 'OTHER' wall (the flying-blind core) [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 312 | ✅ | 🎁 **live-run-legibility** · 🚀 **v0_15** · Live run header — stage stepper + active-agent indicator + live token counter [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 313 | ✅ | 🎁 **live-run-legibility** · 🚀 **v0_15** · Run timing — Status/gen_statem timestamps -> live elapsed + per-stage durations [D:4/B:4/U:3 → Eff:0.88?] ⚠️ |
| Task 314 | ✅ | 🎁 **live-run-legibility** · 🚀 **v0_15** · Live transcript chrome — current-activity line, last-event heartbeat, file +/- chips, turn/tool summary [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 315 | ✅ | 🎁 **live-run-legibility** · 🐛 Run-detail tracks the verdict-recovery reviewer pass — surface its live pid/transcript/elapsed, not the prior pass's timed-out fields [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 322 | ✅ | 🎁 **model-availability** · Antigravity is no longer model-incapable — agy 1.0.10 gained --model + a multi-model catalog; make the adapter model-capable [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 323 | ✅ | 🎁 **core-loop** · Add an integration tripwire: each worktree_isolation:true adapter actually isolates to its run worktree (harness skips the pollution snapshot on trust) [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 324 | ✅ | 🎁 **core-loop** · 🐛 Stabilize cold precommit temp-worktree spawn flake observed by post-merge audit [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 326 | ⬜ | 🎁 **core-loop** · 🚀 **v0_16** · 🐛 Stabilize residual erl_child_setup spawn flake in worktree-heavy suite (Harness.AuditTest noop) [D:4/B:4/U:3 → Eff:0.88] ⚠️ |
| Task 327 `[P]` | ✅ | 🎁 **contract** · Invert the rule-content seam + make Invocation agent-agnostic (AgentAdapter no longer names Harness.AgentRules) [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 328 `[P]` | ✅ | 🎁 **contract** · Break the Driver -> Run.Reflex -> Worktree.Isolation -> AgentAdapter dependency cycle [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 329 | ⛔ | 🎁 **contract** · Decision spike: extract the decoupled AgentAdapter subsystem to its own hex package? [D:2/B:5/U:4 → Eff:2.25] 🎯 |
| Task 330 | ✅ | 🎁 **operator-surface** · Widen over-tight mix.exs dep constraints + guard against regression [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 331 | ✅ | 🎁 **operator-surface** · Dependency-freshness fact source (per-language provider; hex.outdated first) + dashboard panel [D:4/B:6/U:7 → Eff:1.62?] 🚀 |
| Task 332 | ✅ | 🎁 **operator-surface** · Operator 'update deps' action: dispatch a dep-bump through the agent-gate [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 333 | ✅ | 🎁 **operator-surface** · Scheduled full-suite (incl. integration) health check per project -> dashboard witness [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 334 | ✅ | 🎁 **operator-surface** · Tooling-baseline conformance fact source (framework + Elixir provider) + dashboard [D:4/B:6/U:7 → Eff:1.62?] 🚀 |
| Task 335 | ✅ | 🎁 **operator-surface** · Dispatch 'bring project to tooling baseline' through the agent-gate [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 336 | ✅ | 🎁 **operator-surface** · Rust dependency-freshness provider (cargo outdated) for the freshness fact source [D:4/B:5/U:6 → Eff:1.38?] 📋 |
| Task 337 | ✅ | 🎁 **core-loop** · Clean up concrete Reach smell findings: narrow rescues, MapSet membership, direct map iteration [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 338 | ✅ | 🎁 **core-loop** · Triage Reach repeated-map-shape findings into structs, explicit contracts, or documented suppressions [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 339 | ✅ | 🎁 **operator-surface** · Clean up existing Sobelow findings in code_search [D:3/B:4/U:5 → Eff:1.5?] 🚀 |
| Task 340 | ✅ | 🎁 **operator-surface** · Project languages invariant + multi-language provider substrate [D:6/B:8/U:8 → Eff:1.33?] 📋 |
| Task 341 | ✅ | 🎁 **operator-surface** · JavaScript/TypeScript dependency-freshness provider for npm/pnpm/yarn projects [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 342 | ✅ | 🎁 **operator-surface** · Go dependency-freshness provider for go.mod projects [D:4/B:4/U:5 → Eff:1.12?] 📋 |
| Task 343 | ✅ | 🎁 **resilience** · Run gen_statem crashes with case_clause when cancel reason is {:redispatched, run_id} [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 346 `[P]` | ✅ | 🎁 **postgres-results** · 🐛 Port the Task-163 evidence-preserving record_run merge to ResultStore.Memory [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 347 `[P]` | ✅ | 🎁 **resilience** · 🐛 Worktree sweeper is depth-blind: */* glob never finds leaked landing/audit worktrees after a crash mid-land [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 348 `[P]` | ✅ | 🎁 **chat-orchestrator** · 🐛 Chat session lifecycle: broadcast the :busy terminal (silent message drop) + idle-reap immortal session processes [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 349 `[P]` | ✅ | 🎁 **dashboard-perf** · ProjectRegistry.list/0 refetches landing settings once per project — batch the overlay to one read [D:2/B:4/U:3 → Eff:1.75?] 🚀 |
| Task 350 `[P]` | ✅ | 🎁 **postgres-results** · 🐛 AgentKPI.duration_summary/1 crashes with ArithmeticError on [] — reachable from the Postgres KPI rollup [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 352 | ✅ | 🎁 **postgres-results** · Bound run_records growth: blob retention that never touches the countable KPI facts [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 353 | ✅ | 🎁 **core-loop** · Decompose the 2,890-line Run gen_statem: extract per-state event handling into satellite modules [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 354 | ⛔ | 🎁 **resilience** · Run gen_statem crashes with case_clause on {:cancel, {:redispatched, run_id}} after reflex redispatch [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 355 | ⛔ | 🎁 **autolanding** · Land-conflict resolver dies on {:model_required, Claude} — candidate selection must skip model-less agents [D:2/B:5/U:6 → Eff:2.75?] 🎯 |
| Task 356 `[P]` | ✅ | 🎁 **chat-orchestrator** · 🐛 Chat turn-worker crash must fail fast to the caller — monitor instead of bare receive; map ensure_session already_started [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 357 | ✅ | 🎁 **core-loop** · Decompose Harness.Run.Actions (2,575 lines) by lifecycle concern [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 385 | ⬜ | 🎁 **core-loop** · 🐛 Strip the harness-injected ephemeral AGENTS.md header before committing the delivery [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 386 | ⬜ | 🎁 **core-loop** · Lander: landing job can complete (landed_sha recorded) without the roadmap advance ever reaching origin [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 392 | ⬜ | 🎁 **core-loop** · 🐛 Terminate the agent process tree, not just the direct PID — orphaned children outlive the kill and share the worktree [D:5/B:9/U:8 → Eff:1.7] 🚀 |
| Task 393 | ✅ | 🎁 **core-loop** · 🐛 Fence .harness/review.json to the reviewer that wrote it — a killed reviewer's stale approve can settle the run :done [D:3/B:9/U:8 → Eff:2.83] 🎯 |
| Task 396 | ✅ | 🎁 **contract** · Create the harness_agent_adapter package — move the AgentAdapter subsystem into its own repo [D:5/B:6/U:5 → Eff:1.1] 📋 |
| Task 397 | ✅ | 🎁 **contract** · harness consumes harness_agent_adapter as a dependency — delete the in-repo AgentAdapter subsystem [D:5/B:5/U:4 → Eff:0.9] ⚠️ |
| Task 398 | ⬜ | 🎁 **agent-gate** · Injected agent rules must never be visible in a tracked file while an agent runs the project's checks [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 399 | ⬜ | 🎁 **core-loop** · Agent-initiated question channel — implementer parks the run with .harness/question.json, orchestrator answers via steer/resume [D:5/B:6/U:5 → Eff:1.1] 📋 |
| Task 400 | ✅ | 🎁 **autolanding** · Self-land must not mutate the running harness node's own checkout — Git.TargetSync needs a self-host guard [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 401 | ✅ | 🎁 **audit-hygiene** · mix ci is red on main: one ex_dna clone and four dialyzer warnings, all pre-dating the 397 extraction [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 402 | ✅ | 🎁 **audit-hygiene** · Activate the registered ExSlop Credo checks instead of discarding them from the explicit enabled list [D:1/B:4/U:3 → Eff:3.5] 🎯 |
| Task 410 | ✅ | 🎁 **agent-gate** · 🐛 Worktree CoW clone passes the macOS-only `cp -c` flag, so every Linux warm copy silently degrades to a full byte copy [D:3/B:7/U:7 → Eff:2.33] 🎯 |
| Task 411 | ⬜ | 🎁 **agent-gate** · 🐛 run_records read path discards a whole row when one persisted atom is absent from the reading node [D:3/B:6/U:5 → Eff:1.83] 🚀 |
<!-- TASKS:END -->

---

## Phase 23: Audit Hardening — findings from the 2026-07-12 project health audit

<!-- TASKS:BEGIN phase=23 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 358 | ✅ | 🎁 **audit-perf** · 🚀 **v0_16** · Bound KPI dashboard fleet-wide aggregate reads on run settlement [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 359 | ⬜ | 🎁 **audit-architecture** · 🚀 **v0_16** · Split the ~1900-line Harness.Dispatch god module into per-concern modules behind a thin facade [D:5/B:5/U:4 → Eff:0.9?] ⚠️ |
| Task 360 | ⬜ | 🎁 **audit-architecture** · 🚀 **v0_16** · Establish one-way core → consumer layering and break the 71-module strongly-connected cycle [D:7/B:6/U:5 → Eff:0.79?] ⚠️ |
| Task 361 | ✅ | 🎁 **audit-tests** · 🚀 **v0_16** · Add direct coverage for Harness.Store.EtsScope create/lookup and owner-exit table ownership [D:2/B:5/U:4 → Eff:2.25] 🎯 |
| Task 362 | ⬜ | 🎁 **audit-tests** · 🚀 **v0_16** · 🐛 Diagnose and eliminate the AgentRegistry empty-registry test flake [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 363 | ✅ | 🎁 **audit-hygiene** · 🚀 **v0_16** · 📝 🔒 Document the mountable-consumer auth boundary for the dashboard / Oban Web / MCP router [D:1/B:5/U:4 → Eff:4.5?] 🎯 |
| Task 364 | ⬜ | 🎁 **audit-hygiene** · Decision: resolve the anubis_mcp LGPL-3.0 runtime-dependency licensing exposure on the public repo [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 365 | ✅ | 🎁 **run-history** · 🐛 ResultStore.Postgres list/aggregate path fails whole query on atom decode — tolerant row decode like the File store [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 372 | ⛔ | 🎁 **dashboard-observability** · Persist witness events as a shared, queryable human+agent timeline [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 373 | ⬜ | 🎁 **run-history** · 🚀 **v0_17** · Per-adapter/model activity trail across runs and agent seats [D:5/B:6/U:6 → Eff:1.2] 📋 |
| Task 374 | ⬜ | 🎁 **run-history** · 🚀 **v0_17** · Unified append-only lifecycle event log (harness_events) — every run action becomes a durable, queryable fact [D:8/B:7/U:4 → Eff:0.69] ⚠️ |
| Task 376 | ⬜ | 🎁 **test-suite-perf** · Landing tests leak an empty temp repo dir per run into the shared worktree root [D:2/B:4/U:5 → Eff:2.25] 🎯 |
| Task 377 | ⬜ | 🎁 **resilience** · Retry safe post-land cleanup and reclaim historical run branches/worktree orphans [D:4/B:5/U:5 → Eff:1.25] 📋 |
| Task 378 `[P]` | ✅ | 🎁 **roadmap-durability** · Durable roadmap writes ignore roadmap_path and push tasks.toml into the source repo [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 379 | ⬜ | 🎁 **roadmap-writeback** · 🚀 **v0_16** · 🐛 Durable roadmap writeback silently produced no commit — dispatch-start and post-land transitions both lost [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 380 | ⬜ | 🎁 **audit-perf** · 🚀 **v0_16** · Fetch each project target once per landed-sha reconciliation pass [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 381 | 🔄 | 🎁 **audit-perf** · 🚀 **v0_16** · Make capped dashboard transcript append linear in incoming chunk size [D:2/B:4/U:3 → Eff:1.75] 🚀 |
| Task 382 | ⬜ | 🎁 **audit-perf** · 🚀 **v0_16** · Remove the per-lookup Postgres landing-settings round trip from ProjectRegistry [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 383 | ⬜ | 🎁 **resilience** · 🐛 Delivery commit exclusion missed .harness/agent-rules.md — harness's own scaffolding rode in a deliverable [D:3/B:6/U:5 → Eff:1.83] 🚀 |
| Task 384 | ✅ | 🎁 **deferred** · Migrate anubis_mcp 1.x -> 2.0.0 (Application callback removal, transport/supervision rewrite) [D:5/B:3/U:2 → Eff:0.5] ⚠️ |
| Task 389 | ✅ | 🎁 **config-surface** · 🚀 **v0_16** · Expose roadmap_target_branch on the operator registration surfaces [D:3/B:6/U:5 → Eff:1.83] 🚀 |
| Task 391 | 🔄 | 🎁 **surface** · Four `roadmap-mark_*` MCP tools expose zero parameters — declare their params, then guard the class [D:3/B:6/U:6 → Eff:2.0] 🎯 |
| Task 403 | ✅ | 🎁 **audit-hygiene** · 🚀 **v0_16** · 🔒 Make the loopback posture true: Origin/Host guard on /harness/mcp + source-URL validation before git clone [D:2/B:9/U:7 → Eff:4.0] 🎯 |
| Task 404 | ✅ | 🎁 **audit-perf** · 🚀 **v0_16** · Take the uncached SettingsStore reads and the synchronous CLI catalog probes off the 5s settings tick [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 405 | ✅ | 🎁 **roadmap-writeback** · 🚀 **v0_16** · 🐛 Audit discovery filing writes into the operator's live checkout and is never committed [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 413 | ✅ | 🎁 **witness-legibility** · Surface an in-flight audit signal on the fleet count strip, not just the ops panel [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 414 | ⬜ | 🎁 **config-surface** · 🐛 Give dispatch-register_project a typed languages schema so MCP clients can send a JSON array [D:3/B:7/U:6 → Eff:2.17] 🎯 |
<!-- TASKS:END -->
