---
sha: 5291698
short_sha: 5291698
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 43 Dogfood verification reds on pre-existing TODO comments in dispatch base

**Original commit:** 5291698 — Task 43 completion (Claude)
**Files touched:** 2 lib/ + tests + docs (271 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | Cat 1/6 | lib/harness/verification/baseline_filter/credo.ex:124,205 + test/harness/verification/baseline_filter/credo_test.exs:136 | Suite doesn't catch the main diff-aware boundary: inherited TODOs that move lines, or carry through a rename. Filter is exact `{path, line}` — Codex verified with `filter_issues/3` that baseline `{lib/inherited.ex, 3}` keeps an issue at `/wt/lib/inherited.ex:4` (line-shift miss) | Applied: same content-keyed migration as `d4344e7`'s Finding 1+2 — baseline keys on `{file, normalized_content}`. Regression tests now pin the line-shift case. rmap follow-up filed as Task 55. |
| 2 | 6 | Cat 1 / tests | lib/harness/verification/baseline_filter/credo.ex:61,140 + test/harness/verification/baseline_filter/credo_test.exs:122 | No happy-path test exercises `apply/2` through real Credo JSON rerun. Defensive `apply/2` tests + bypass-acceptance tests. A regression in `credo_issues/1`, JSON parsing, or command args would pass | Noted. End-to-end `apply/2` requires a runnable mix project as a fixture (slow & non-trivial). Out of scope here — the `filter_issues/3` + `regrade/3` + `baseline_tagtodo_lines/2` units cover the surface; `apply/2`'s I/O wiring is thin. File a future task if regressions appear. |

## Auto-applied fixes

- (covered by the content-keyed fix landed against `d4344e7` earlier in this audit)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjaimvx-73e9sp`). Task 55 covers the content-keyed migration.
