---
sha: bc5ac65
short_sha: bc5ac65
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 30 Pin Worktree.commit/2 to the run's harness/<id> branch

**Original commit:** bc5ac65 — Task 30 delivery (Claude)
**Files touched:** 2 lib/ + tests + docs (111 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | doc-gap | roadmap/tasks.toml:858 (Task 30 `implemented`) | Note claims "explicit refspec" but the shipped code asserts HEAD-on-branch via `rev-parse` + `symbolic-ref` and uses plain `git add -A` — different mechanism than the implementation note claims | Applied: implementation note rewritten to match shipped code (`asserts HEAD-on-branch …` + `{:head_moved, where}` error variant) |
| 2 | 5 | doc-gap | CHANGELOG.md `### Fixed` | No Fixed entry for the `commit/2` branch-pinning change at audit time | Applied: CHANGELOG `### Fixed` entry added — `Harness.Worktree.commit/2` now asserts HEAD-on-branch before staging; `{:commit_failed, {:head_moved, where}}` settlement |
| 3 | 4 | doc-gap | ROADMAP.md (Task 30 row) | Status not flipped at agent-delivery commit | Historical — by repo convention the agent-delivery commit ships code; the closeout commit (77cea24) flips status. No action. |

## Auto-applied fixes

- `roadmap/tasks.toml` Task 30 `implemented` rewritten to match shipped code.
- `CHANGELOG.md` `### Fixed` gained a Task 30 entry.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjagf9p-y99jm2`).
