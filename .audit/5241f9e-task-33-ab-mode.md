---
sha: 5241f9e29d89cf50c8dda869a063739a0b118acd
short_sha: 5241f9e
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: findings-noted (2 follow-ups filed as Tasks 67, 68; CHANGELOG applied)
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 33 Same-task A/B agent-evaluation mode

**Original commit:** 5241f9e — `harness: agent delivery — task 33 Same-task A/B agent-evaluation mode (run run-1779853579933-6fa47408)`
**Author:** harness (Cursor delivery)
**Files touched:** 4 (lib/harness/batch.ex, lib/harness/batch/agent_evaluation.ex new, skills/harness-driver/SKILL.md, test/harness/batch/agent_evaluation_test.exs new)
**LOC:** +467

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 8 | bug (codex) | lib/harness/batch.ex:331 | `run_pinned/3` settles the entire remaining pinned queue when the first pinned adapter is unavailable pre-dispatch; B never runs after A is marked unavailable. | **Filed as Task 67** — pinned-mode dispatch semantics need a `settle_one` variant. Auto-fix scoped out (small refactor + test). |
| 2 | 5 | bug (codex) | lib/harness/batch/agent_evaluation.ex:110 | `from_batch/3`'s `Enum.zip(batch.results, adapters)` truncates to the shorter list, silently dropping results when lengths disagree. | **Filed as Task 68** — contract choice (raise vs pad) plus docstring + regression test. |
| 3 | 6 | doc-gap (codex) | CLAUDE.md long status paragraph | Codex flagged the paragraph still saying Task 33 "orphaned, rolled back to pending". | dropped — the paragraph is the broader phase-history narrative and needs a full Round refresh, not a single-sentence patch; would be inconsistent surgery. Flagged for next CLAUDE.md sweep. |
| 4 | 5 | doc-gap (codex) | CHANGELOG.md | Meaningful public surface (`Batch.run_pinned/3` + `Batch.AgentEvaluation.compare/4`) lacked an `[Unreleased]` entry. | **Applied:** added under `### Added`. |
| 5 | — | acceptance | — | One task fans to N adapters via pinned batch; comparison reports per-agent verdict, repair_attempts, duration_ms, first_attempt_failed_check_count, agent_diff_size. ✅ | met |
| 6 | — | acceptance | — | Adapter fail-over never crosses pins (each slot uses `[Enum.at(pinned, index)]` only). ✅ | met |
| 7 | — | acceptance | — | Metrics are additive — verification stack stays binary pass/fail. ✅ | met |

## Auto-applied fixes

- `CHANGELOG.md` `[Unreleased] ### Added` — Task 33 entry (A/B agent evaluation + `Batch.run_pinned/3`).

## Discuss-tier resolutions

— None.

## Codex second-opinion

Status: dual-reviewer (jobId task-mpnoxbrm-ox3oi8).
Corroborated findings: —
Codex-only findings (verified + applied): 4 (CHANGELOG).
Codex-only findings (filed as rmap follow-ups): 1 (Task 67), 2 (Task 68) — both are real-but-narrow contract bugs that need design choices, not mechanical fixes.
Codex-only findings (dropped): 3 (CLAUDE.md paragraph refresh — broader sweep needed).

Codex's verification: `mix test.json --quiet test/harness/batch/agent_evaluation_test.exs` 4/4 passing; `mix credo` and `mix dialyzer.json` sandbox-blocked on TCP `:eperm`.
