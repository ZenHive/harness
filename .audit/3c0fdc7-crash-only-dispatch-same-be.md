---
sha: 3c0fdc72922b14f8ed5dc69f3aa7627c9c4d7da9
short_sha: 3c0fdc7
audited_at: 2026-06-04
auditor_model: claude-opus-4-8
verdict: discuss-required
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: crash-only dispatch + same-BEAM worktree reaper (tasks 180, 185)

**Files touched:** 4 lib/ files + tests **LOC:** ±434

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | discuss-design | bug | reaper.ex (cleanup_for_run/maybe_reap) | monitor :DOWN vs Run.Registry unregister ordering race | dropped + filed task 191 |

## Auto-applied fixes
- (none)

## Discuss-tier resolutions
- reaper race (DIVERGENCE — Claude flagged, Codex found nothing): when a run gen_statem crashes, the reaper's :DOWN and the Registry auto-unregister are unordered; if :DOWN lands first, cleanup_for_run's live_run? guard refuses the reap and the worktree leaks until the boot Sweeper (degrades to pre-task-185 behavior). Self-heals on next boot, not a crash. No convergent fix between reasoners → dropped from auto-apply, filed as task 191 for the user's call (retry-on-refused-live vs accept boot-Sweeper backstop).

## Codex second-opinion
Status: dual-reviewer
Corroborated findings: —
Codex-only (verified): — (Codex reported no findings on this commit)
Note: crash?/1 correctly treats :normal/:shutdown/{:shutdown,_} as non-crash; drop_run demonitors with [:flush]; reaper starts before Run.Supervisor.
