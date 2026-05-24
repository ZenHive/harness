---
sha: 015869f
short_sha: 015869f
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: fix: silence Round-4 verification false-positives (sobelow_skip + :jason plt_add_apps)

**Original commit:** 015869f — preset tightening closeout for Tasks 36 + 43
**Files touched:** 2 lib/ + mix.exs (17 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 4 | doc-gap | CHANGELOG.md `### Fixed` | CHANGELOG records Task 36 + Task 43 but doesn't explicitly note the closeout's preset tightening (sobelow_skip + `:jason` plt addition) | Applied: CHANGELOG `### Fixed` gained an entry — `Verification` preset tightened to silence Round-4 false positives without weakening the gate |

## Auto-applied fixes

- `CHANGELOG.md` `### Fixed` gained the preset-tightening entry.

## Non-findings (verified clean)

- Sobelow skip annotations sit on private helpers whose paths are fixed or derived via `worktree_file!/2` (path-disciplined; cannot escape the worktree root).
- `:jason` PLT scope is correct — narrower than switching to transitive deps under `plt_add_deps: :apps_direct`.
- No new unprefixed "for now/currently/temporarily/in production" text in the diff.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjaiueh-5ns8ws`).
