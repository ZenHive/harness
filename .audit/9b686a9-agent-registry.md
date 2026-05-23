---
sha: 9b686a9b6b4438bf823a759c01a89bbfe5d6b165
short_sha: 9b686a9
audited_at: 2026-05-23
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: agent capability + availability registry with quota fail-over (Task 16)

**Original commit:** 9b686a9 — `feat: agent capability + availability registry with quota fail-over (Task 16)`
**Author:** E.FU
**Files touched:** 8
**LOC:** +437 / -42

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 9   | bug | lib/harness/batch.ex (fill_slots — select pattern match) | `{:ok, adapter} = AgentRegistry.select(...)` crashes the batch with `MatchError` after every capable adapter has been marked unavailable by fail-over; queued items + active runs are orphaned (claude + codex) | dropped to rmap follow-up Task 34 |
| 2 | 7   | bug | lib/harness/batch.ex (fill_slots — start_run pattern match) | `{:ok, run_id, pid} = RunSupervisor.start_run(...)` crashes the batch if start_run returns `{:error, _}` (now possible after Task 16's re-check in Run.Supervisor) — race between Batch's `select` and the supervisor's re-check (claude + codex) | dropped to rmap follow-up Task 35 |
| 3 | discuss-design | bug | lib/harness/agent_registry.ex (GenServer state) | Registry availability state is in-process memory only; a supervised restart resets quota-unavailable adapters and they become re-selectable (codex) | dropped to rmap follow-up Task 40 |
| 4 | 5   | doc-gap | CLAUDE.md (Architecture) | Architecture section omits `Harness.AgentRegistry` — the new orchestrator-facing gate, runtime availability tracking, quota fail-over (codex) | dropped — this dogfood batch's close-out commit (738c6bda) already adds the `AgentRegistry` CHANGELOG entry; CLAUDE.md Architecture is a deliberate high-level sketch, not an exhaustive catalogue |
| 5 | 6   | doc-gap | ROADMAP.md / CHANGELOG.md | Task 16 completes but ROADMAP and CHANGELOG are not updated in the same commit (codex) | dropped — by design per the dogfooding workflow; close-out commit 738c6bda paired status flip + CHANGELOG entry. Codex doesn't know the dogfooding pattern |

## Auto-applied fixes

- (none in this report — the doc fixes for CLAUDE.md AgentAdapter contract are recorded against a133e34 / 826aaff; the bug findings (#1, #2, #3) are dropped to rmap follow-ups because each resolution requires a design decision among multiple defensible options.)

## Discuss-tier resolutions

- **Finding 1 (`bug` pri 9, dropped to rmap Task 34):** Both Claude and Codex agreed this is a real `MatchError` crash path. Reproduction: 2-item batch with 1 capable adapter that quota-exhausts on item 1. Item 1's fail-over marks the adapter unavailable; `fill_slots/6` re-enters for item 2; `select/2` returns `{:error, {:no_available_agent, _}}`; the unmatched `:error` tuple crashes the batch process. Active runs become orphaned. Resolution options: (a) handle the error and settle queued items with `{:no_available_agent, _}` reason; (b) atomic select-then-reserve API. Filed as rmap Task 34.

- **Finding 2 (`bug` pri 7, dropped to rmap Task 35):** Claude+Codex agreed. The race is narrow but real under concurrent batches: `Batch.fill_slots` calls `select`, gets `:ok`; before `RunSupervisor.start_run/4` runs, another batch marks the adapter unavailable; `start_run/4` re-checks and returns `{:error, ...}`; the unmatched tuple crashes the batch. Filed as rmap Task 35 — could be resolved together with Task 34 via an atomic reservation API.

- **Finding 3 (`discuss-design`):** Codex flagged that quota state is GenServer memory only. Three contract options recorded in the follow-up (rmap Task 40): persist across restarts; document the reset semantics; TTL-based soft unavailability. The decision is a deliberate user-side architectural call.

- **Findings 4, 5 (dropped):** Codex's CLAUDE.md / ROADMAP / CHANGELOG flags reflect the dogfooding workflow's deliberate separation between code commits and close-out commits. Round-2 close-out (738c6bda) is the paired doc update. Filed-by-mistake had Codex applied the close-out edit here, the dogfood pattern's audit trail would be muddier.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1, 2 (both flagged by Claude AND Codex independently — high-confidence Cat 1 bugs)
Codex-only findings (filed as follow-up): 3 (registry restart state → rmap Task 40)
Codex-only findings (discarded as over-flag): 4, 5 (dogfooding workflow's deliberate close-out separation)

Verification notes: Codex's tools could not run (sandbox `:eperm`/`:descripex`). Both reviewers verified the bug shape against the committed code directly. The MatchError pattern in `fill_slots/6` was independently identified by both reviewers — strong corroboration for a non-cosmetic Cat 1.
