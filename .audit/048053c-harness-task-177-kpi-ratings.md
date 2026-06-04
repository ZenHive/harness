---
sha: 048053cb44f9963d1e34a6c17d7b9613b74bf005
short_sha: 048053c
audited_at: 2026-06-04
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 177 Reviewer KPI ratings feed AgentKPI/CapabilityScore + reviewer rejection-rate tracking

**Files touched:** 7 lib/ files + tests **LOC:** ±621

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug | audit.ex:217 | `false \|\| configured()` ignores explicit result_store: false | applied + test |
| 2 | 4 | doc-gap | CHANGELOG.md | no [Unreleased] entry for the task-177 surface | applied |
| 3 | 3 | extraction | audit.ex:236 | bare 500 truncation magic number | applied |

## Auto-applied fixes
- lib/harness/audit.ex:217 — `Map.get(request, :result_store) || ResultStore.configured()` → `Map.get(request, :result_store, ResultStore.configured())`. store() type explicitly includes false/nil as disable-sentinels (moduledoc + @type store), so an explicit `result_store: false` was silently re-enabled via the configured fallback. Trigger: Audit.run(%{..., result_store: false}) with a configured store present → rejection history the caller disabled leaks into the audit prompt.
- test/harness/audit_test.exs — added regression: explicit result_store: false disables the lookup even when a store is configured with a matching rejection (refutes leak, asserts empty-section framing).
- lib/harness/audit.ex:43,236 — extracted bare 500 to @rejection_summary_limit.
- CHANGELOG.md [Unreleased] → Added — task-177 entry (reviewer rejection rollup, rating_means, CapabilityScore mean_ratings + ratings tiebreaker, prioritize_reviewers/2, audit false-rejection feedback loop).

## Discuss-tier resolutions
- (none)

## Codex second-opinion
Status: dual-reviewer
Corroborated findings: —
Codex-only (verified, applied): 1 (audit.ex:217 store-disable bug), 3 (magic 500)
Claude-only (applied): 2 (CHANGELOG gap)
Note: tiebreaker weights sum <1 (success_rate primacy preserved); ratings_efficiency caps [0,1], 0.0 for unrated; numeric_ratings ignores non-numbers; reviewer_rejection_rates best-effort, bounded @500, newest-first.
