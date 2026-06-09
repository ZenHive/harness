---
sha: 72edccd9b2e41cb31f0e8b0d46c29bee65462465
short_sha: 72edccd
audited_at: 2026-06-09
auditor_model: claude-opus-4-8
verdict: clean
codex_status: single-reviewer (10-LOC revert)
audited_by: audit-review v1
---

# Audit: fix(dashboard): revert /harness roadmap deferral that hung the render (task 241)

**Author:** E.FU · **Files:** lib/harness/dashboard/live.ex · **LOC:** ±10

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | (none) | — | Restores mount-time roadmap population (parallelized via for_projects) | clean |

## Notes
Reverts the empty-`:roadmap`-at-mount deferral from 5adfcb3: an empty summaries map made `RunFeed.landed_sha` fall through to a per-row `git fetch` (×200 history rows), hanging the render. Restoring mount-time population short-circuits landed rows on the roadmap witness again (~31ms). The real root cause — network git on the render path — is fixed properly in 65b9a10 (task 244). Clean revert with an excellent commit-message narrative.
