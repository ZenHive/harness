---
sha: d12a3a70a8b394fd6452e83898a932bc22f12476
short_sha: d12a3a7
audited_at: 2026-06-04
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: dashboard run-history Delete + ResultStore.delete_run/2

**Files touched:** 5 lib/ files + tests **LOC:** ±345

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 3 | doc-gap | result_store.ex:21 | moduledoc disabled-store enumeration omits delete_run | applied |
| 2 | discuss-trivial | extraction | live.ex:386 | prune_history/deletable? public def vs defp | verified keep (tested publicly) |

## Auto-applied fixes
- lib/harness/result_store.ex:21 — added `delete_run` to the "both values short-circuit ..." disabled-store enumeration (delete_run/2 short-circuits on false/nil at result_store.ex:183-184; was omitted).

## Discuss-tier resolutions
- prune_history/2 + deletable?/1 (Claude discuss-trivial): proposed def→defp demotion was contingent on test usage. Verified test/harness/dashboard/live_test.exs:140-152, 219-234 call Live.deletable?/1 and Live.prune_history/2 directly — public access is justified; kept as `def`.

## Codex second-opinion
Status: dual-reviewer
Corroborated findings: —
Codex-only (verified): 1 (delete_run moduledoc gap — applied)
Note: File delete_run sobelow-skipped w/ justification (harness path, idempotent on :enoent); Postgres delete_all idempotent on 0 rows; both @impl+@spec.
