# harness Roadmap

**Vision:** An OTP-native task-execution engine an AI orchestrator drives end to end — it pulls tasks from the rmap roadmap, dispatches each to a headless coding agent (Claude, Codex, Cursor, Grok, Antigravity, Pi) in an isolated worktree, gates the result with a cross-family reviewer AI (which runs the target project's own checks itself and fixes inline), merges approved work, audits landed commits post-merge with a third agent, and reports the reviewer's verdicts back over an agent-shaped surface (Elixir API / LiveView dashboard / MCP tools). The agent-gate workflow — `worktree → implementer AI → reviewer AI → MERGE → audit AI` — is the architecture; judgment lives in agents, harness code is mechanical substrate only ([docs/agent-gate-workflow.md](docs/agent-gate-workflow.md)).

**Task tracking:** This file is rendered by `rmap` from `roadmap/tasks.toml`. Don't hand-edit the task tables inside `<!-- TASKS:BEGIN -->` / `<!-- TASKS:END -->` marker pairs — they're regenerated on every `rmap render`. Edit `roadmap/tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`, then `rmap render`. Prose outside the marker pairs is byte-preserved.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md).

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** 23 — Audit Hardening — findings from the 2026-07-12 project health audit (2 of 15 done · 0 in progress)

**Last shipped:** Task 378 — Durable roadmap writes ignore roadmap_path and push tasks.toml into the source repo on 2026-08-05

**Up next:** Task 363 — Document the mountable-consumer auth boundary for the dashboard / Oban Web / MCP router [D:1/B:5/U:4 → Eff:4.5] 🎯
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
> 22 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-4-multi-agent-quota-fail-over).
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
| Task | Status | Notes |
|------|--------|-------|
| Task 75 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_7** · Annotate harness driver surface with descripex api() macros [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 76 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_7** · Harness.Chat.Session GenServer with multi-turn tool-call loop [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 77 | ⛔ | 🎁 **chat-orchestrator** · 🚀 **v0_7** · Harness.Chat.Anthropic backend — Req + streaming + prompt caching + tool-use [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 78 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_7** · Harness.Dashboard.ChatLive — LiveView UI for chat orchestrator [D:4/B:8/U:6 → Eff:1.75?] 🚀 |
| Task 79 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_7** · Headless MCP endpoint — /harness/mcp/tools + /harness/mcp/call [D:2/B:7/U:8 → Eff:3.75?] 🎯 |
| Task 82 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_7** · 🐛 Harness.Chat.Claude headless subscription backend (default) [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 83 | ✅ | 🎁 **chat-orchestrator** · 🐛 Fix anubis StreamableHTTP transport — initialize crashes with :badarg, blocks all MCP tool exposure to claude -p [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 84 | ✅ | 🎁 **chat-orchestrator** · 🐛 Add Harness.Dashboard.ErrorHTML so dashboard 500s don't cascade into Phoenix.Template crashes [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 93 | ✅ | 🎁 **chat-orchestrator** · Chat session persistence + index page — survive restart, list & reopen past chats [D:5/B:6/U:5 → Eff:1.1?] 📋 |
| Task 95 | ✅ | 🎁 **chat-orchestrator** · Chat UI: add stop/cancel control to streaming session [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 96 | ✅ | 🎁 **chat-orchestrator** · Chat: clear streaming indicator on :terminal events, not only :done [D:1/B:4/U:5 → Eff:4.5?] 🎯 |
| Task 367 `[P]` | ✅ | 🎁 **agent-gate** · Reviewer task filings become review.json proposals; orchestrator files them post-land [D:6/B:8/U:8 → Eff:1.33] 📋 |
| Task 368 `[P]` | ✅ | 🎁 **core-loop** · Coalesce-dispatch: run N small same-bundle tasks as one implementer run [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 369 | ✅ | 🎁 **autolanding** · Lander fallback: mechanically resolve additive-only tasks.toml conflicts by renumbering [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 370 | ✅ | 🎁 **core-loop** · 🐛 Settle-persist must survive schema/DB drift: never silently lose a run record on a failed insert [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 371 `[P]` | ⛔ | 🎁 **agent-gate** · Close the post-land CHANGELOG gap: no workflow step owns writing entries [D:3/B:6/U:7 → Eff:2.17] 🎯 |
<!-- TASKS:END -->

---

## Phase 10: Dashboard Operator UX

<!-- TASKS:BEGIN phase=10 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 85 | ✅ | 🎁 **dashboard-chrome** · 🚀 **v0_8** · Harness.Dashboard.Components + Tokens overhaul + persistent navbar/footer chrome [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 86 | ✅ | 🎁 **dashboard-chrome** · 🚀 **v0_8** · Transcript parser dispatch + per-agent parsers (5 structured + 1 passthrough) with unified event vocabulary [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 87 | ✅ | 🎁 **dashboard-chrome** · 🚀 **v0_8** · Run-detail transcript rework — parsed event list + <.transcript_view> component, ?raw=1 fallback [D:5/B:9/U:9 → Eff:1.8?] 🚀 |
| Task 88 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_8** · Harness.Roadmap browse tools (roadmap__list / roadmap__next_bundle) + descripex 0.7 param_order dispatch fix [D:4/B:7/U:8 → Eff:1.88?] 🚀 |
| Task 89 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_8** · Harness.Playbooks — orchestration recipe tools (playbooks__list / playbooks__get) [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 90 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_8** · Dashboard playbook prefill buttons — chip row over the chat composer [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 91 | ✅ | 🎁 **chat-orchestrator** · 🚀 **v0_8** · Flat MCP-native dispatch tool — make the chat orchestrator able to dispatch a task for any project [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 94 | ✅ | 🎁 **dashboard-chrome** · 🚀 **v0_8** · Kill button for in-flight runs on the dashboard [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 105 | ✅ | 🎁 **run-history** · Surface persisted run history in the dashboard (index list + drill-down replay) [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 107 | ✅ | 🎁 **run-history** · Event-driven dashboard run tables (RunFeed) + per-project history filtering [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 126 | ✅ | 🎁 **dashboard** · Run change-set view on the run-detail page (live edited-files + settled git diff) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 165 | ✅ | 🎁 **config-centralization** · Consolidate the Cron/Agent/Landing settings term files into one Postgres-backed settings store (file fallback) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 166 | ⛔ | 🎁 **config-centralization** · ConfigInspector reads defaults from owning modules; drop sections deleted by the reviewer-pair pass [D:2/B:4/U:3 → Eff:1.75?] 🚀 |
| Task 167 | ✅ | 🎁 **config-centralization** · Harness.Config declarative schema + UI-editable operational knobs (run timeouts) [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 178 | ✅ | 🎁 **dashboard-chrome** · Formalize Harness.Dashboard.Transcript.Parser as a behaviour (@callback new/feed/finalize) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 193 | ✅ | 🎁 **config-centralization** · Per-project reviewer override (%Harness.Project{reviewer}) + Run.init overlay + select_reviewer consults it + Settings-page runtime override [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
<!-- TASKS:END -->

---

## Phase 11: Autonomous Landing

<!-- TASKS:BEGIN phase=11 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 20 | ✅ | 🎁 **autolanding** · Per-run token capture — efficiency signal + predictive quota fail-over [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 98 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Thread body + acceptance_criteria onto %Roadmap.Item{} through ingestion [D:3/B:6/U:8 → Eff:2.33?] 🎯 |
| Task 99 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Cross-family adversarial semantic gate on green verdicts [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 100 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Autonomous merge-train — serialized lander (happy path) [D:5/B:8/U:9 → Eff:1.7?] 🚀 |
| Task 101 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Merge-train resilience — post-merge repair, conflict re-dispatch, blocked sink [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 102 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Witness notification sink (read-only, hard to become a gate) [D:2/B:6/U:7 → Eff:3.25?] 🎯 |
| Task 103 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · dispatch__await — blocking dispatch tool for chat/MCP [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 108 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Thread env scrubbing through Oban Run.Worker so dispatch__bundle honors scrub_anthropic_key [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 109 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Cron autonomy master toggle — runtime enable/disable from the dashboard, persisted [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 110 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Per-project cron autonomy flag — pause/resume autonomy per registered project [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 111 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Cron schedule editing from the UI — boot-applied presets, optional live reconfig [D:4/B:2/U:2 → Eff:0.5?] ⚠️ |
| Task 112 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Mid-run reflex floor — progress-stall detector + unified deterministic watchdog [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 113 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Continuous in-run discernment — sampled cross-family Buddhi on the witness stream [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 123 | ✅ | 🎁 **autolanding** · Decouple semantic gate from auto-land so dogfooding dispatches get green-verdict scrutiny [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 127 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Configuration inspector LiveView — read-only operator view of the resolved harness config [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 128 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Per-agent enable/disable from the Settings page [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 129 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Cron poller: dispatch the parallel-safe ready batch, skip handbuild [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 130 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Route autonomous dispatch on assignee — consume rmap's formalized agent-routing field, stop overloading model [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 131 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Cron poller: mark dispatched tasks in_progress to stop re-dispatch of completed-but-unlanded work [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 133 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Project dispatch queues not started at boot — enqueued runs sit 'available' forever [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 134 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Dashboard run feed is stale: no live-update for out-of-band runs + no persistent history [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 143 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · 🐛 Verification bootstraps the worktree (deps seed / setup step) — stop grading on a missing-deps environment [D:4/B:7/U:8 → Eff:1.88?] 🚀 |
| Task 147 | ✅ | 🎁 **core-loop** · 🚀 **v0_9** · Warm worktree at provision time — run check-stack setup (deps.get + deps.compile) before agent dispatch [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 148 | ✅ | 🎁 **autolanding** · 🐛 StatusView.classify/1 missing :consulting — concurrent suite crashes poison every dispatched run's verification [D:1/B:5/U:4 → Eff:4.5?] 🎯 |
| Task 150 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Run recovery — hold/steer/resume gen_statem API (operator-mediated mid-run recovery) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 152 | ✅ | 🎁 **autolanding** · 🐛 Flaky 150 test: cancel/1-from-:held times out under full-suite load (run_test.exs:750) [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 153 | ✅ | 🎁 **autolanding** · 🐛 Verification can't attribute red to the agent — a pre-existing red base yields false-red verdicts [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 154 `[CX]` | ✅ | 🎁 **autolanding** · 🐛 Cron dispatch leaks provider API keys (ANTHROPIC/OPENAI) — subscription agents bypass their login (Task 108 follow-through) [D:2/B:8/U:7 → Eff:3.75?] 🎯 |
| Task 155 | ✅ | 🎁 **autolanding** · 🚀 **v0_9** · Per-project landing policy + Dispatch now from the Settings page [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 156 | ✅ | 🎁 **autolanding** · 🐛 MCP dispatch-task runs are not restart-resilient — a node restart silently kills in-flight runs with no record [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 157 | ✅ | 🎁 **autolanding** · 🐛 Resume/rescue orphaned in-flight runs after a BEAM restart (Oban executing-row zombie) [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 158 | ✅ | 🎁 **autolanding** · 🐛 Post-green semantic gate rejects green runs when the grader is unavailable (no auto-pair OR disabled grader == reject; Task-59 parity gap) [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 159 | ✅ | 🎁 **autolanding** · 🐛 `:no_changes` cancels before verifying — an already-implemented task wedges in_progress instead of being graded/landed [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 160 | ✅ | 🎁 **autolanding** · 🐛 Baseline run skips diff-aware post_process — agent-caused credo findings masked as :base_red, repair loop never fires [D:2/B:7/U:7 → Eff:3.5?] 🎯 |
| Task 171 | ✅ | 🎁 **autolanding** · 🐛 Lander.Worker ignores the runtime landing override — dashboard auto-land fails with :no_target_branch [D:1/B:8/U:8 → Eff:8.0?] 🎯 |
| Task 172 | ⛔ | 🎁 **autolanding** · 🐛 Lander: land a branch that is checked out in a retained run worktree (worktree add --detach) [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 189 | ✅ | 🎁 **autolanding** · *Harness.Lander.Resilience* · Lander conflict-resolver agent: on rebase conflict, spawn a cross-family merge AI to resolve in-place instead of re-dispatching [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 281 | ✅ | 🎁 **autolanding** · dispatch-reland on rebase-conflict re-dispatches a fresh implementer instead of retaining the branch [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 282 | ✅ | 🎁 **autolanding** · Reviewer-stage git-add fatals on gitignored .harness/ → review_stuck blocks the gate; .harness-retained artifact leaks into commits [D:3/B:8/U:7 → Eff:2.5?] 🎯 |
| Task 345 | ⛔ | 🎁 **autolanding** · Lander conflict-resolver spawns without resolving the agent model — every resolve fails {:model_required, adapter} [D:2/B:7/U:7 → Eff:3.5?] 🎯 |
<!-- TASKS:END -->

---

## Phase 12: Workflow Substrate

<!-- TASKS:BEGIN phase=12 -->
> 2 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-12-workflow-substrate).
<!-- TASKS:END -->

---

## Phase 13: Agent KPIs & Capability Routing

<!-- TASKS:BEGIN phase=13 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 114 | ✅ | 🎁 **production-kpis** · 🚀 **v0_10** · Harness.AgentKPI — per-agent KPI aggregation over result_store run records [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 115 | ✅ | 🎁 **production-kpis** · 🚀 **v0_10** · Per-agent KPI dashboard LiveView — the at-a-glance trust ledger [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 116 | ✅ | 🎁 **capability-bench** · 🚀 **v0_10** · Capability domain taxonomy + per-run domain tagging (the lynchpin) [D:4/B:8/U:10 → Eff:2.25?] 🎯 |
| Task 117 | ✅ | 🎁 **capability-bench** · 🚀 **v0_10** · Benchmark corpus structure + loader — fixed, versioned eval set separate from the live roadmap [D:6/B:8/U:8 → Eff:1.33?] 📋 |
| Task 118 | ✅ | 🎁 **capability-bench** · 🚀 **v0_10** · Initial Elixir-domain benchmark corpus content (OTP / LiveView / Oban / Ecto) [D:6/B:8/U:8 → Eff:1.33?] 📋 |
| Task 119 | ✅ | 🎁 **capability-bench** · 🚀 **v0_10** · Capability scoring + persistence — per-(agent,domain) score from AgentEvaluation comparisons [D:6/B:10/U:10 → Eff:1.67?] 🚀 |
| Task 120 | ✅ | 🎁 **capability-bench** · 🚀 **v0_10** · Capability score staleness / decay + re-benchmark-needed signal [D:2/B:6/U:8 → Eff:3.5?] 🎯 |
| Task 121 | ✅ | 🎁 **kpi-routing** · 🚀 **v0_10** · recommend-agent-per-domain routing surface (explore/exploit) in the dispatch path [D:6/B:10/U:10 → Eff:1.67?] 🚀 |
| Task 122 | ✅ | 🎁 **kpi-routing** · 🚀 **v0_10** · Oban cron capability-benchmark scheduler — fill unmeasured/stale cells autonomously [D:6/B:8/U:8 → Eff:1.33?] 📋 |
| Task 137 | ✅ | 🎁 **postgres-results** · 🚀 **v0_10** · Postgres-backed result store — run_records/batch_results schemas + ResultStore.Postgres backend + repo_enabled config flip [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 138 `[P]` | ✅ | 🎁 **postgres-results** · mix harness.import_results — one-shot file-store to Postgres importer [D:2/B:2/U:2 → Eff:1.0?] 📋 |
| Task 139 `[P]` | ✅ | 🎁 **postgres-results** · 🚀 **v0_10** · Dashboard/KPI SQL fast paths — aggregate in Postgres instead of loading every run record into memory [D:3/B:4/U:5 → Eff:1.5?] 🚀 |
| Task 144 | ✅ | 🎁 **production-kpis** · 🚀 **v0_10** · Capture requested model through dispatch so codex/grok runs show a model on the dashboard [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 145 | ✅ | 🎁 **postgres-results** · 🚀 **v0_10** · 🐛 Verification can't grade :integration-tagged tests — DB-backed code passes green while broken against real Postgres [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 146 | ✅ | 🎁 **postgres-results** · 🚀 **v0_10** · 🐛 MCP result_store-list_run_records rejects JSON-caller filters (no function clause matching) [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 151 | ⛔ | 🎁 **capability-bench** · 🚀 **v0_10** · Agent evaluation corpus — stand up the Elixir corpus repo + prove Mode-B hidden-grader isolation [D:4/B:5/U:4 → Eff:1.12?] 📋 |
| Task 246 | ✅ | 🎁 **kpi-routing** · 🚀 **v0_14** · ResultStore MCP read tools resolve configured() store when param omitted (KPIs read empty via MCP) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 258 | ✅ | 🎁 **postgres-results** · Reviewer-reliability + facet SQL fast paths — finish what Task 139 started [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 259 | ✅ | 🎁 **chat-orchestrator** · 🐛 Fix the MCP param boundary once and for all — typeless kind:value coercion silently returns empty/wrong [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 260 | ✅ | 🎁 **postgres-results** · Fix stale LandingSettings default-target_branch assertion in settings_store/postgres_test.exs:36 [D:1/B:2/U:2 → Eff:2.0?] 🎯 |
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
| Task 174 | ⬜ | 🎁 **reviewer-pair** · Live-agent E2E smoke test: one real headless agent CLI through the full pipeline, :integration/:live_agent tagged [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 179 | ⛔ | 🎁 **reviewer-pair** · SMOKE: add a one-sentence summary line to Harness.LineBuffer @moduledoc [D:1/B:1/U:1 → Eff:1.0?] 📋 |
| Task 183 | ⛔ | 🎁 **agent-gate** · Smoke test (throwaway): add Harness.LineBuffer.empty?/1 predicate + test [D:1/B:1/U:1 → Eff:1.0?] 📋 |
| Task 186 | ✅ | 🎁 **agent-gate** · 🔒 Neuter the push remote in harness-created worktrees so in-run agents can't push/PR past landing_policy [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 188 | ✅ | 🎁 **agent-gate** · 🔒 Scrub GH_TOKEN/GITHUB_TOKEN from in-run env + assess the gh pr create vector (push-neuter follow-up) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
<!-- TASKS:END -->

---

## Phase 16: Agent-Gate Workflow & Post-Merge Audit

<!-- TASKS:BEGIN phase=16 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 170 | ⛔ | 🎁 **audit-agent** · 🚀 **v0_12** · Post-merge audit agent: cron-triggered batch audit of the unaudited commit range, verified by the check stack, landed by the merge-train [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 175 | ✅ | 🎁 **agent-gate** · 🚀 **v0_12** · Agent-gate workflow rebuild: reviewer AI is THE gate, no mechanical verification anywhere [D:8/B:10/U:10 → Eff:1.25?] 📋 |
| Task 176 | ✅ | 🎁 **audit-agent** · 🚀 **v0_12** · Post-merge audit agent: per-land enqueue, third-family auditor, audit(...) commits ff-pushed [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 177 | ✅ | 🎁 **agent-gate** · 🚀 **v0_12** · Reviewer KPI ratings feed AgentKPI/CapabilityScore rollups + reviewer rejection-rate tracking [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 180 | ✅ | 🎁 **agent-gate** · 🚀 **v0_12** · 🐛 Settled-:failed run teardown kills the Oban worker before {:cancel} returns -> wrongful retry storm (up to max_attempts=20) [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 181 | ✅ | 🎁 **agent-gate** · 🚀 **v0_12** · 🐛 Reviewer can finish work but skip writing .harness/review.json and idle-timeout -> run lost to :review_stuck [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 182 | ✅ | 🎁 **agent-gate** · 🚀 **v0_12** · Settings page: per-agent reviewer-eligibility toggle (distinct from implementer enable) + select_reviewer consults it [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 185 | ✅ | 🎁 **agent-gate** · 🚀 **v0_12** · 🐛 Same-BEAM :DOWN reaper reclaims the worktree+branch a live-run cleanup-refusal leaks when that run later crashes [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 190 | ✅ | 🎁 **audit-agent** · *Harness.Oban* · Start the global :audit Oban queue so the post-merge audit AI actually runs [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 191 | ✅ | 🎁 **agent-gate** · Audit-surfaced: Worktree reaper vs Run.Registry unregister ordering race [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 192 | ✅ | 🎁 **audit-agent** · Audit-surfaced: Task 190 — add real insert-and-drain test for the :audit Oban queue [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 194 | ✅ | 🎁 **audit-agent** · Clean (:no_changes) post-merge audit leaves no watermark — range re-audited every land [D:3/B:2/U:3 → Eff:0.83?] ⚠️ |
| Task 195 | ✅ | 🎁 **resilience** · 🐛 Run.Worker crash-recovery: idempotent worktree setup so an Oban retry after BEAM restart reuses the run's branch instead of colliding [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 196 | ✅ | 🎁 **resilience** · 🐛 Runs branch from origin/<target>, not operator-checkout HEAD — fetch origin before worktree create so dispatched runs always build on the latest landed code [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 197 | ✅ | 🎁 **resilience** · Lander auto-fast-forwards the operator's local target ref when safe, so a land does not leave local development drifting behind origin [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 198 | ✅ | 🎁 **resilience** · 🐛 Antigravity (agy) adapter leaks writes into the operator checkout instead of the run worktree — worktree isolation regression [D:5/B:8/U:4 → Eff:1.2?] 📋 |
| Task 199 | ✅ | 🎁 **resilience** · 🐛 Run wedges in :reviewing when the reviewer process is never tracked (reviewer=nil) — add an idle/progress watchdog so a lost reviewer fails fast instead of holding a queue slot to the 90-min lifetime cap [D:5/B:6/U:5 → Eff:1.1?] 📋 |
| Task 200 | ✅ | 🎁 **resilience** · Bound spawned-run process memory: kill a run whose agent/check_command process tree runs away (it OOM'd the host twice) [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 201 | ✅ | 🎁 **resilience** · 🐛 Reorder terminate_reviewer/terminate_agent before cancel_task in the general cancel/lifetime/fail handlers [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 202 | ✅ | 🎁 **resilience** · Node-pressure dispatch gate: hold new run admission under high host memory (AC3 follow-up to task 200) [D:4/B:2/U:3 → Eff:0.62?] ⚠️ |
| Task 203 | ✅ | 🎁 **agent-gate** · Reviewer missing-verdict recovery: re-prompt the reviewer once before discarding the run [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 204 | ✅ | 🎁 **agent-gate** · Dashboard Resume + Re-land buttons: recover failed runs & blocked land-trains [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 205 | ✅ | 🎁 **agent-gate** · 🐛 Verify + declare auth_env_scrub for Cursor/Grok/Pi/Antigravity adapters [D:2/B:2/U:2 → Eff:1.0?] 📋 |
| Task 206 | ✅ | 🎁 **agent-gate** · 🐛 Scrub provider auth API keys from spawned agent CLIs (subscription billing) [D:2/B:7/U:6 → Eff:3.25?] 🎯 |
| Task 207 | ✅ | 🎁 **agent-gate** · *Harness.Config* · Configurable default dispatch agent (unassigned tasks → codex, not claude) [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 245 | ✅ | 🎁 **agent-gate** · 🚀 **v0_14** · *Harness.Run.Worker* · Run-lifecycle in_progress claim survives concurrent tasks.toml writers [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 253 | ✅ | 🎁 **agent-gate** · 🐛 MCP api() param coercion breaks guarded fns: await/5 (float timeout_ms) + list_run_records/1 (map filters) [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 254 | ✅ | 🎁 **agent-gate** · 🐛 decode_param: JSON-string-encoded keyword/object params from MCP clients (completes 253's list_run_records AC) [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 255 | ✅ | 🎁 **agent-gate** · Per-role reviewer model — split the reviewer model from the implementer's per-agent default [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 256 | ✅ | 🎁 **agent-gate** · Per-agent default model — operator-configurable Config.agent_model, threaded onto implementer + reviewer Invocations [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 262 | ✅ | 🎁 **operator-surface** · 📝 Expose operator read-state (agents, reviewers, autonomy, config) + self-describe via descripex MCP surface [D:3/B:4/U:4 → Eff:1.33?] 📋 |
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
| Task 375 | ⬜ | 🎁 **config-surface** · Validate optional %Harness.Project{} fields at registration — an uncast concurrency_cap silently kills batch dispatch [D:2/B:6/U:6 → Eff:3.0] 🎯 |
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
| Task 326 | ⬜ | 🎁 **core-loop** · 🚀 **v0_16** · 🐛 Stabilize residual erl_child_setup spawn flake in worktree-heavy suite (Harness.AuditTest noop) [D:4/B:4/U:3 → Eff:0.88?] ⚠️ |
| Task 327 `[P]` | ✅ | 🎁 **contract** · Invert the rule-content seam + make Invocation agent-agnostic (AgentAdapter no longer names Harness.AgentRules) [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 328 `[P]` | ✅ | 🎁 **contract** · Break the Driver -> Run.Reflex -> Worktree.Isolation -> AgentAdapter dependency cycle [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 329 | ⬜ | 🎁 **contract** · Decision spike: extract the decoupled AgentAdapter subsystem to its own hex package? [D:2/B:5/U:4 → Eff:2.25] 🎯 |
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
<!-- TASKS:END -->

---

## Phase 23: Audit Hardening — findings from the 2026-07-12 project health audit

<!-- TASKS:BEGIN phase=23 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 358 | ⬜ | 🎁 **audit-perf** · 🚀 **v0_16** · Bound dashboard fleet-wide and per-call reads — unindexed aggregates, per-run git fetch, per-chunk buffer copy, uncached lookup [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 359 | ⬜ | 🎁 **audit-architecture** · 🚀 **v0_16** · Split the ~1900-line Harness.Dispatch god module into per-concern modules behind a thin facade [D:5/B:5/U:4 → Eff:0.9] ⚠️ |
| Task 360 | ⬜ | 🎁 **audit-architecture** · 🚀 **v0_16** · Establish one-way core → consumer layering and break the 71-module strongly-connected cycle [D:7/B:6/U:5 → Eff:0.79] ⚠️ |
| Task 361 | ⬜ | 🎁 **audit-tests** · 🚀 **v0_16** · Unit-test the untested merge-critical modules Harness.Git.TargetSync and Harness.Store.EtsScope [D:3/B:7/U:5 → Eff:2.0] 🎯 |
| Task 362 | ⬜ | 🎁 **audit-tests** · 🚀 **v0_16** · 🐛 De-flake the AgentRegistry global-state cross-test pollution class (resolver_test + reviewer-selection) [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 363 | ⬜ | 🎁 **audit-hygiene** · 🚀 **v0_16** · 📝 🔒 Document the mountable-consumer auth boundary for the dashboard / Oban Web / MCP router [D:1/B:5/U:4 → Eff:4.5] 🎯 |
| Task 364 | ⬜ | 🎁 **audit-hygiene** · Decision: resolve the anubis_mcp LGPL-3.0 runtime-dependency licensing exposure on the public repo [D:2/B:5/U:4 → Eff:2.25] 🎯 |
| Task 365 | ✅ | 🎁 **run-history** · 🐛 ResultStore.Postgres list/aggregate path fails whole query on atom decode — tolerant row decode like the File store [D:3/B:7/U:7 → Eff:2.33] 🎯 |
| Task 372 | ⛔ | 🎁 **dashboard-observability** · Persist witness events as a shared, queryable human+agent timeline [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 373 | ⬜ | 🎁 **run-history** · 🚀 **v0_17** · Durable agent identity — per-actor audit trail across runs and seats [D:5/B:6/U:6 → Eff:1.2] 📋 |
| Task 374 | ⬜ | 🎁 **run-history** · 🚀 **v0_17** · Unified append-only lifecycle event log (harness_events) — every run action becomes a durable, queryable fact [D:8/B:7/U:4 → Eff:0.69] ⚠️ |
| Task 376 | ⬜ | 🎁 **test-suite-perf** · Landing tests leak an empty temp repo dir per run into the shared worktree root [D:2/B:4/U:5 → Eff:2.25] 🎯 |
| Task 377 | ⬜ | 🎁 **resilience** · No GC for landed run branches or orphaned run worktrees — 272 branches accumulated [D:4/B:5/U:5 → Eff:1.25] 📋 |
| Task 378 `[P]` | ✅ | 🎁 **roadmap-durability** · Durable roadmap writes ignore roadmap_path and push tasks.toml into the source repo [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 379 | ⬜ | 🎁 **roadmap-writeback** · 🐛 Durable roadmap writeback silently produced no commit — dispatch-start and post-land transitions both lost [D:4/B:7/U:7 → Eff:1.75] 🚀 |
<!-- TASKS:END -->
