---
sha: 35f2c0486d0d4da639c62ad241457c0983d374aa
short_sha: 35f2c04
audited_at: 2026-06-04
auditor_model: claude-opus-4-8
verdict: discuss-required
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: reviewer verdict-write reframed as mandatory FINAL action + 10-min reviewing idle floor (task 181); :audit queue boot-start coverage (task 190)

**Files touched:** 1 lib/ file + tests + roadmap **LOC:** ±276

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | acceptance | roadmap/tasks.toml (task 190) | AC#2 (insert→drain) met only by config-presence proxy | filed task 192 |

## Auto-applied fixes
- (none)

## Discuss-tier resolutions
- task 190 acceptance gap (Codex pri 5; Claude rated commit clean): AC#2 explicitly required "a test that inserts an audit job and observes it run/drain rather than a guard that only checks insertion." Shipped coverage is a {:audit,1} in oban_opts()[:queues] config-presence assert + the worker's existing perform-routing drain tests, justified by the offline suite (oban_enabled:false, repo_enabled:false). Defensible for offline, but does not satisfy the criterion as written. Acceptance gaps are never auto-fixed in audit-review — filed as task 192 (integration insert→drain test). Task 190 status left done (the queue-start itself shipped and works).

## Codex second-opinion
Status: dual-reviewer
Corroborated findings: —
Codex-only (verified → rmap follow-up): 1 (task 190 AC#2)
Note: reviewer_idle_timeout/1 total over timeout()|nil (nil→floor, :infinity→:infinity, int→max(idle,floor)); @reviewer_idle_floor documented with the concrete idle-kill incident.
