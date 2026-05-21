---
sha: 29699284e89818c1e179632d621feceaf7c5d6d1
short_sha: 2969928
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: worktree-per-job lifecycle + rmap task ingestion (Tasks 5, 6)

**Original commit:** 2969928 — `feat: worktree-per-job lifecycle + rmap task ingestion (Tasks 5, 6)`
**Author:** E.FU
**Files touched:** 19
**LOC:** +1169 / -27

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | note | lib/harness/worktree/sweeper.ex | Boot sweep reaps every unmarked worktree under `base_dir` — a second harness instance sharing `base_dir` could delete an in-flight run's worktree | Note only — see below |

## Auto-applied fixes

- (none)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex-only findings (verified): —
Codex-only findings (discarded as over-flag):
- `sweeper.ex:57` cross-instance worktree deletion (pri 8) — **recorded as a
  note, not applied.** Real only if two harness OS processes share one
  `base_dir`; that is outside the documented single-instance model (within one
  instance the boot sweep runs before any run starts, so there is no race). A
  guard ("is this worktree's run still alive?") would be genuine hardening but
  the multi-instance scenario is speculative — surfaced for the maintainer's
  judgment, not auto-fixed.
- `worktree.ex:87` nested-id worktree leaks the `*/*` sweep glob (pri 5) —
  **discarded.** Reachable only via the `id:` option with an embedded slash;
  that option is test-only and generated ids (`run-<ts>-<hex>`) never contain
  slashes.
- `roadmap.ex:116` `decode_task/1` accepts a JSON map with no `"title"`,
  yielding `%Item{title: nil}` (pri 5) — **discarded.** rmap's task schema
  always emits a title; not reachable through the real `rmap` surface.
- ROADMAP / README / CLAUDE.md "still says Phase 1" (pri 3-4) — **discarded.**
  Point-in-time observations of the commit snapshot; later commits updated
  CLAUDE.md, and the committed `ROADMAP.md` at HEAD is in sync with
  `roadmap/tasks.toml` (`rmap validate --check-render` → `valid`).
