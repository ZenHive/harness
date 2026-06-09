---
sha: 028b062fdef463395d69c29443620cf451fc7780
short_sha: 028b062
audited_at: 2026-06-09
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat(dashboard): surface audit + lander lifecycle on /harness ops feed (task 243)

**Author:** E.FU · **Files:** 12 (NEW ops_feed.ex + ops_feed/op.ex; audit.ex, lander.ex, lander/resilience.ex, live.ex, +tests) · **LOC:** ±596

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 8 | bug | ops_feed.ex:79 | `cap/1` tail-cut splits a UTF-8 codepoint → invalid binary crashes ops-panel render | **applied** (Claude + Codex) |
| 2 | 5 | doc-gap (codex) | roadmap/tasks.toml | Task 243 still in_progress *in this commit* | dropped — done at HEAD via 21d876b |

## Auto-applied fixes
- **lib/harness/dashboard/ops_feed.ex** `cap/1`: the 16,000-byte tail slice can begin mid-codepoint; the transcript renders directly in a LiveView `<pre>`, so an invalid binary crashes the render (and `Jason.encode!` raises before the diff is sent — Codex's precise trigger: `"a"*10 <> "€" <> "b"*15999`). Added `trim_leading_to_valid_utf8/1` (drops ≤3 leading bytes until `String.valid?`), mirroring `chat_live.ex`'s established `trim_to_valid_utf8`. Added a multibyte-boundary test to `ops_feed_test.exs` (15/15 green; the test fails against the pre-fix raw `binary_part`).

## Discuss/dropped
- **Finding 2:** Codex flagged task 243 as `in_progress` in this commit (Cat 6). Verified false-positive-at-HEAD: the next commit `21d876b` flips it to `done --shipped-in 028b062 --verified`. This is the repo's established implement-then-flip workflow; no gap at HEAD.

## Codex second-opinion
Status: dual-reviewer. **Corroborated finding 1** (priority 8, independent precise trigger) and observed the fix was already in the worktree. Confirmed: `audit_outcome/1`/`land_outcome/1` cover all declared outcome shapes (no bad `:unknown` fallthrough); no mantra violation (op.ex relabels facts, never computes a verdict). Codex's roadmap-status flags (243) verified resolved at HEAD.
