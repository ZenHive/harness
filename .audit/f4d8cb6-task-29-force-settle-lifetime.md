---
sha: f4d8cb6
short_sha: f4d8cb6
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 29 Force-settle the Run lifetime timeout when the agent handle never arrives

**Original commit:** f4d8cb6 — Task 29 delivery (Claude)
**Files touched:** 1 lib/ + tests + docs (79 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 8 | bug | lib/harness/run.ex:505 | Codex Pri-8 claim: deferred `cancel/1` callers hang when lifetime force-settles before the agent handle arrives. Probe reported `cancel_requested: {:cancelled, from}`, result `:timed_out`, `Task.yield(cancel_task, 500) == nil` | **Investigated and partly applied — claim does NOT reproduce against the shipped code.** `force_settle_lifetime/1` already calls `pending_cancel_reply(data)` (line 509) and returns the `[{:reply, from, :ok}]` action *before* clearing `cancel_requested`. The deferred reply IS threaded into the gen_statem return tuple. The real gap was test coverage: the composed scenario (cancel-before-handle + force-settle) had no deterministic regression test, so a future refactor could re-introduce the bug. **Action:** filed Task 56 (`Audit-surfaced: cover cancel-before-handle path in Run lifetime force-settle`) and shipped the regression test in `test/harness/run_test.exs` as part of this audit commit. Test passes against current code — confirms the reply path works today. |
| 2 | 7 | doc-gap | ROADMAP.md (Task 29 row at f4d8cb6) | Status not flipped at delivery commit | Historical. No action. |
| 3 | 6 | doc-gap | CHANGELOG.md `### Fixed` | No `[Unreleased]` entry for the force-settle timeout behavior change | Applied: CHANGELOG `### Fixed` entry added — `Run` force-settles `:timed_out` even when `{:run_handle, _}` never arrives; `force_settle_lifetime/1` replies to deferred cancel callers |

## Auto-applied fixes

- `test/harness/run_test.exs` — added the `REGRESSION (Task 56)` test pinning the cancel-before-handle + lifetime-force-settle composition (passes against current code).
- `CHANGELOG.md` `### Fixed` gained the Task 29 entry.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjagopt-mqvgc5`). Claim was investigated against the shipped code and the gap was test coverage, not behavior — see Finding 1 resolution above. rmap follow-up filed (Task 56) to track the regression test landing.
