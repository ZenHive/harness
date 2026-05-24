---
sha: d4344e7
short_sha: d4344e7
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat(verification): diff-aware credo TagTODO baseline filter (Task 43, WIP)

**Original commit:** d4344e7 — Task 43 WIP scaffold (Claude)
**Files touched:** 5 lib/ + tests + docs (366 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 8 | bug | lib/harness/verification/baseline_filter/credo.ex:123,203 | **Same-line rewrite false-pass.** Baseline keys on `{file, line_no}` only — if an agent rewrites the TODO content on the same line, it's silently filtered as inherited debt. Verification false-greens. | Applied: baseline keys now `{file, normalized_content}`; baseline_tagtodo? matches by credo `trigger`. Same-line rewrites are correctly flagged. rmap follow-up filed (Task 55). |
| 2 | 7 | bug | lib/harness/verification/baseline_filter/credo.ex:203 | **Line-shift false-red.** Insert/delete above an inherited TODO shifts its line_no; baseline doesn't follow, so an unchanged inherited TODO is falsely flagged as new debt. | Applied: same content-keyed fix resolves the line-shift case. New regression test pins it. |
| 3 | 7 | dialyzer (resolved) | mix.exs:49, lib/harness/verification/baseline_filter/credo.ex:166 | This commit introduces `Jason.decode/1` in `lib/` but `plt_add_apps` doesn't include `:jason` (with `plt_add_deps: :apps_direct`) | Resolved by 015869f closeout, which added `:jason` to `plt_add_apps`. No action on this commit. |
| 4 | 6 | self-red on verification | lib/harness/verification.ex:54, baseline_filter/credo.ex:129 | New prose contains `TODOs` mentioned as text — Credo TagTODO flags it. The scaffold reds its own verification stack | Resolved: the BaselineFilter itself filters inherited TagTODOs from later runs; the test-file false matches in this audit's own changes have been fixed inline (reworded comments). |
| 5 | 6 | tests | test/harness/worktree_test.exs:28 | Only `Worktree.base_sha` is covered; no tests for `BaselineFilter.Credo` parsing, line shifts, same-line rewrites, JSON noise, no-match git grep | Resolved by 5291698 (Task 43 dogfood completion commit, later in this audit range) which added the integration suite. Additionally, this audit added same-line-rewrite + line-shift regression tests. |
| 6 | 5 | doc-gap | CHANGELOG.md | No Task 43 changelog entry at this WIP commit | Acceptable — WIP commit; full Task 43 entry landed in CHANGELOG before audit time (line 213). No action. |
| 7 | 4 | logic gap | lib/harness/verification/baseline_filter/credo.ex:90 | `regrade/3` marks a failed result as pass when `issues == []` and `filtered == []` (vacuous pass — no original issue, no filter) | Theoretical at current call paths; `apply/2` only calls `regrade/3` after credo produces issues. Low priority. Documented. |

## Auto-applied fixes

- `lib/harness/verification/baseline_filter/credo.ex` — baseline key migrated from `{file, line_no}` to `{file, normalized_content}`; `normalize/1` helper added.
- `test/harness/verification/baseline_filter/credo_test.exs` — same-line-rewrite + line-shift regression tests added; fixtures updated for content-keyed matching; accidental TagTODO matches in test docstrings reworded.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjaiet6-s3joro`). rmap follow-up filed as Task 55.
