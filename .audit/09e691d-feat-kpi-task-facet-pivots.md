---
sha: 09e691dd01dfae15fe3db23a01fab748463d56df
short_sha: 09e691d
audited_at: 2026-06-09
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat(dashboard): /harness/kpi pivots by task-facet — per-agent ledger + scout verdict (task 225)

**Author:** E.FU · **Files:** kpi_live.ex, tokens.ex, +tests · **LOC:** ±360

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | doc-gap (codex) | roadmap/tasks.toml | Task 225 still pending *in this commit* | dropped — done at HEAD via 7b140a1 |

## Discuss/dropped
- **Finding 1:** Codex flagged task 225 `pending` in this commit (Cat 6). Verified false-positive-at-HEAD: `7b140a1` flips it `done --shipped-in 09e691d --verified`. Implement-then-flip workflow; no gap at HEAD.

## Notes
Pivots the per-agent KPI ledger by reviewer-assigned `review_facets` via `CapabilityScore.group_by_facet/1`, with the scout's written verdict (`read_assessment/1`) beside the fact rows. **THE MANTRA verified clean:** `quality/1` is a mean of already-counted reviewer-rating means (explicitly "not a routing verdict"); the winner/route text comes from the scout's assessment artifact, never recomputed from numbers. `normalize_facet`/`verdict_index` use order-independent map-key matching (sound). Both store reads degrade to empty on error. Well-tested (92 LOC).

## Codex second-opinion
Status: dual-reviewer. Refuted any mantra violation ("KPI computes fact rows/means, routing winner text comes from read_assessment/1"); confirmed facet map-key matching consistent. Only flag = finding 1 (verified resolved at HEAD).
