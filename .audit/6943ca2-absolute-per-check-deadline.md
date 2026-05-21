---
sha: 6943ca269a73bb67caed1946ae336b6b8d6f7bc9
short_sha: 6943ca2
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: absolute per-check deadline + Result.kind for verification timeouts

**Original commit:** 6943ca2 — `feat: absolute per-check deadline + Result.kind for verification timeouts`
**Author:** E.FU
**Files touched:** 5
**LOC:** +91 / -22

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug | lib/harness/verification.ex (`collect/5`) | A check flooding stdout fast enough to keep the mailbox non-empty starves the `after` clause — `receive` always matches `{:data, _}`, so the absolute deadline never fires | Applied: pre-`receive` deadline guard |
| 2 | 3 | doc-gap | lib/harness/verification.ex:75 | `run/2` `:timeout` doc says "in milliseconds" but `:infinity` is now accepted and tested | Applied: docstring mentions `:infinity` |

## Auto-applied fixes

- `lib/harness/verification.ex` — `collect/5` now checks `deadline_passed?/1`
  before each `receive`; a flooding check is killed at the deadline instead of
  starving the timeout. The timed-out `Result` construction was extracted into
  `timed_out_result/4` (shared by the new guard and the `after` clause). This
  closes the gap the commit's own docstring claimed was covered ("a check still
  streaming output … is killed").
- `lib/harness/verification.ex` — `run/2` `:timeout` option doc now notes
  `:infinity` for an unbounded check (the `deadline/1` / `remaining/1`
  `:infinity` clauses this commit added).

## Discuss-tier resolutions

- (none — finding 1 is a corroborated bug with a mechanical, precedent-shaped
  fix; classified `discuss-trivial` and auto-applied)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (Codex flagged the flood-starvation at pri 8 with the
  concrete `yes` trigger; Claude reached the same conclusion independently)
Codex-only findings (verified): 2 (`:infinity` doc gap — verified against the
  added `deadline(:infinity)` clause)
Codex-only findings (discarded as over-flag):
- `CHANGELOG.md:37` "describes the old per-check timeout, omits the absolute
  deadline + `Result.kind`" (pri 4) — **discarded.** The repo's CHANGELOG
  philosophy (`task-prioritization.md`) is explicit: release notes, not a
  per-task archive. The unreleased `Harness.Verification` entry summarises the
  feature adequately; per-commit refinement detail does not belong there.
