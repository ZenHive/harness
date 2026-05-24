---
sha: d1c177c
short_sha: d1c177c
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 37 Audit-surfaced: Repair loop ignores quota classification before resuming

**Original commit:** d1c177c — Task 37 delivery (Codex)
**Files touched:** 2 lib/ + tests + docs (48 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug (resolved) | lib/harness/batch.ex:298 | Codex flagged a split quota classifier: repair-loop gating uses `RetryPolicy.classify/1` but fail-over still used `AgentRegistry.quota_exhausted?/1` — narrower trigger (no `billing_error` / `429`), so a run could stop repairing as quota-exhausted yet not fail over. | Resolved by **Task 28** (commit 63b711d, later in this audit range) which wires `Harness.Run.RetryPolicy.run/2` through `Harness.Batch`, unifying the classifier on the way through. No action on this commit. |
| 2 | 5 | doc-gap | CHANGELOG.md | No Fixed entry for the Task 37 repair-loop quota-stop refinement | Applied: CHANGELOG `### Fixed` entry added — `RetryPolicy.classify/1` short-circuits `:quota_exhausted` before the repair loop fires |
| 3 | 6 | doc-gap | ROADMAP.md (Task 37 row at d1c177c) | Status not flipped at delivery commit | Historical (agent-delivery / closeout pattern). No action. |

## Auto-applied fixes

- `CHANGELOG.md` `### Fixed` gained the Task 37 entry.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjagtvq-nstb48`).
