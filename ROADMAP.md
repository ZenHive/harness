# harness Roadmap

**Vision:** An OTP-native task-execution engine an AI orchestrator drives end to end — it pulls tasks from the rmap roadmap, dispatches each to a headless coding agent (Claude, Cursor, Codex, Grok) in an isolated worktree, runs the target project's own check stack against the result, and reports verified outcomes back over an agent-shaped surface (MCP tools / JSON CLI).

**Task tracking:** This file is rendered by `rmap` from `roadmap/tasks.toml`. Don't hand-edit the task tables inside `<!-- TASKS:BEGIN -->` / `<!-- TASKS:END -->` marker pairs — they're regenerated on every `rmap render`. Edit `roadmap/tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`, then `rmap render`. Prose outside the marker pairs is byte-preserved.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md).

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** 1 — Foundation (3 of 3 done · 0 in progress)

**Last shipped:** Task 1 — Scaffold the OTP application + standard dep stack, Task 2 — Evaluate orchestration libraries — confirm thin-core, Task 3 — Define the AgentAdapter behaviour — invocation + capture on 2026-05-20

**Up next:** Task 42 — Audit-surfaced: Refresh roadmap focus phase pin after Phase 1 closeout [D:1/B:3/U:4 → Eff:3.5] 🎯
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
| Task | Status | Notes |
|------|--------|-------|
| Task 4 | ✅ | 🎁 **claude-adapter** · 🚀 **v0_1** · Build the Claude Code headless adapter [D:6/B:9/U:9 → Eff:1.5] 🚀 |
| Task 5 `[P]` | ✅ | 🎁 **core-loop** · 🚀 **v0_1** · Worktree-per-job lifecycle [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 6 `[P]` | ✅ | 🎁 **core-loop** · 🚀 **v0_1** · rmap task ingestion [D:3/B:7/U:7 → Eff:2.33] 🎯 |
| Task 7 `[P]` | ✅ | 🎁 **core-loop** · 🚀 **v0_1** · Verification runner — run the target project's check stack [D:5/B:9/U:8 → Eff:1.7] 🚀 |
| Task 8 | ✅ | 🎁 **core-loop** · 🚀 **v0_1** · Supervised run lifecycle process [D:5/B:9/U:9 → Eff:1.8] 🚀 |
| Task 12 | ✅ | 🎁 **contract-proof** · 🚀 **v0_1** · Reusable adapter conformance test suite [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 14 | ✅ | 🎁 **contract-proof** · 🚀 **v0_1** · Codex headless adapter [D:5/B:5/U:5 → Eff:1.0] 📋 |
| Task 24 | ✅ | 🎁 **core-loop** · 🐛 Commit the agent's work to the run branch before worktree teardown [D:3/B:9/U:9 → Eff:3.0] 🎯 |
| Task 27 | ⬜ | 🎁 **contract-proof** · Hoist universal adapter callbacks into the AgentAdapter behaviour [D:3/B:3/U:6 → Eff:1.5] 🚀 |
| Task 30 | ⬜ | 🎁 **core-loop** · Pin Worktree.commit/2 to the run's harness/<id> branch [D:3/B:6/U:4 → Eff:1.67] 🚀 |
<!-- TASKS:END -->

---

## Phase 3: Batch & Resilience

> Concurrent batch fan-out under a `DynamicSupervisor`, a retry policy that classifies transient vs. quota vs. terminal failure, and the autonomous repair loop that feeds red verdicts back to the agent.

<!-- TASKS:BEGIN phase=3 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 9 | ✅ | 🎁 **resilience** · 🚀 **v0_2** · Batch orchestrator with concurrency cap [D:5/B:9/U:8 → Eff:1.7] 🚀 |
| Task 10 `[P]` | ✅ | 🎁 **resilience** · 🚀 **v0_2** · Retry policy with failure classification [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 11 `[P]` | ✅ | 🎁 **resilience** · 🚀 **v0_2** · Autonomous repair loop [D:5/B:8/U:7 → Eff:1.5] 🚀 |
| Task 28 | ⬜ | 🎁 **resilience** · 🚀 **v0_2** · Wire the retry policy into the batch orchestrator [D:4/B:6/U:6 → Eff:1.5] 🚀 |
| Task 29 | ⬜ | 🎁 **resilience** · 🚀 **v0_2** · Force-settle the Run lifetime timeout when the agent handle never arrives [D:3/B:6/U:4 → Eff:1.67] 🚀 |
| Task 34 | ✅ | 🎁 **resilience** · Audit-surfaced: Batch.fill_slots crashes after AgentRegistry exhaustion [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 35 | ⬜ | 🎁 **resilience** · Audit-surfaced: Batch.fill_slots race — start_run errors crash the batch [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 37 | ⬜ | 🎁 **resilience** · Audit-surfaced: Repair loop ignores quota classification before resuming [D:3/B:6/U:5 → Eff:1.83] 🚀 |
| Task 38 | ⬜ | 🎁 **resilience** · Audit-surfaced: Batch slot held until terminal_linger expires [D:3/B:3/U:4 → Eff:1.17] 📋 |
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
| Task 32 | ⬜ | 🎁 **multi-agent** · 🐛 Antigravity adapter does not isolate to its run worktree [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 36 | ⬜ | 🎁 **multi-agent** · Audit-surfaced: Harness-injected rule files get committed by Worktree.commit [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 39 | ⬜ | 🎁 **multi-agent** · Audit-surfaced: Hoist rule injection into the AgentAdapter behaviour [D:4/B:5/U:5 → Eff:1.25] 📋 |
| Task 40 | ⬜ | 🎁 **multi-agent** · Audit-surfaced: AgentRegistry availability lost on GenServer restart [D:3/B:4/U:4 → Eff:1.33] 📋 |
| Task 41 | ⬜ | 🎁 **multi-agent** · 🐛 Codex adapter — worktree isolation breaks intermittently (cwd ignored, agent edits main checkout) [D:5/B:7/U:7 → Eff:1.4] 📋 |
<!-- TASKS:END -->

---

## Phase 5: Surface & Observability

> The agent-shaped entry point — descripex-generated MCP tools + a JSON CLI — plus a human status view and structured run logging, so both the AI orchestrator and the human can see what the fleet is doing.

<!-- TASKS:BEGIN phase=5 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 17 | ⬜ | 🎁 **surface** · 🚀 **v0_4** · Agent-shaped surface — MCP tools + JSON CLI [D:6/B:8/U:8 → Eff:1.33] 📋 |
| Task 18 `[P]` | ✅ | 🎁 **surface** · 🚀 **v0_4** · Human status view [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 19 `[P]` | ✅ | 🎁 **surface** · 🚀 **v0_4** · Structured run logging + result persistence [D:5/B:5/U:5 → Eff:1.0] 📋 |
| Task 33 | ⬜ | 🎁 **surface** · Same-task A/B agent-evaluation mode [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 42 | ⬜ | 🎁 **surface** · Audit-surfaced: Refresh roadmap focus phase pin after Phase 1 closeout [D:1/B:3/U:4 → Eff:3.5] 🎯 |
<!-- TASKS:END -->

---

## Phase 6: Deferred

> Parked work — out of scope until the core milestones ship. Quota-burn telemetry and an ACP transport adapter; both speculative, revisited only when there's a concrete reason.

<!-- TASKS:BEGIN phase=6 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 20 | ⬜ | 🎁 **deferred** · Run telemetry + quota/cost accounting [D:5/B:3/U:3 → Eff:0.6] ⚠️ |
| Task 21 | ⬜ | 🎁 **deferred** · ACP transport adapter [D:7/B:5/U:3 → Eff:0.57] ⚠️ |
<!-- TASKS:END -->
