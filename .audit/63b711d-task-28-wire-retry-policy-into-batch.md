---
sha: 63b711d
short_sha: 63b711d
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 28 Wire the retry policy into the batch orchestrator

**Original commit:** 63b711d — Task 28 delivery (Cursor)
**Files touched:** 1 lib/ + tests + docs (563 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug | lib/harness/batch.ex:269,296 | Worker `run_once_dispatch/5` busy-spins up to 100x on `{:error, {:no_available_agent, _}}` then crashes with `{:run_crashed, :dispatch_spin_exhausted}` instead of routing through the documented `{:no_available_agent, _}` settlement path at line 386. Race: parent sees adapter available → spawns worker → another batch marks unavailable → worker spin path triggered → loses documented settlement | Applied: changed reason to `{:no_available_agent, :spin_exhausted}`; promoted `100` to module attribute `@spin_count_limit`; exposed `run_once_dispatch/5` as `@doc false` for deterministic regression test. rmap follow-up filed as Task 57. |
| 2 | 4 | observability regression | lib/harness/batch.ex:281,340 | `:start_run_failed` event no longer emitted on batch event log when `RunSupervisor.start_run/4` errors (caller-supplied duplicate `:run_id`, etc.) — worker captures the reason in `RunResult` only; observability regression, not result loss | Noted, not addressed in this audit. Out of scope for the spin-exhausted fix; would re-introduce parent/worker coupling for a low-frequency event. File as a future task if it becomes load-bearing. |
| 3 | 6 | leaked artifact (resolved) | .cursor/rules/harness-operational.mdc | Commit included a `.cursor/rules/...` injected-rule artifact unrelated to retry-policy wiring — exactly the harness-injected rule the cleanup hook (Task 36) addresses | Resolved upstream: file removed by 95fe425 (drop pre-fix rule files) and Task 36's `cleanup_injected_rules/1` prevents future leaks. No action. |
| 4 | 6 | doc-gap | ROADMAP.md (Task 28 row at 63b711d); CHANGELOG.md "pending Task 28" wording | Status not flipped at delivery commit; CHANGELOG retry-policy "pending Task 28" line outdated | Applied: CHANGELOG "pending Task 28" rewritten to "Wired into `Harness.Batch` (Task 28, below)" |

## Auto-applied fixes

- `lib/harness/batch.ex` — spin-exhausted fallback now settles `{:no_available_agent, :spin_exhausted}`; `@spin_count_limit 100` attribute introduced; `run_once_dispatch/5` exposed `@doc false` for testability.
- `test/harness/batch_test.exs` — `REGRESSION (Task 57)` test added; passes against the new settlement reason.
- `CHANGELOG.md` — "wiring … is pending Task 28" wording rewritten now that wiring landed.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjahu7r-cudty8`). rmap follow-up filed as Task 57.
