---
sha: 91a74855b3b00a98b26b1ef599c36066e1696a1e
short_sha: 91a7485
audited_at: 2026-06-04
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: per-agent reviewer-eligibility toggle + worktree push-neuter (tasks 182, 186)

**Files touched:** 5 lib/ files + tests **LOC:** ±507

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug | worktree.ex:176/197 | create/2 returns {:ok} even if push-neuter git config fails | verified by-design; no fix |

## Auto-applied fixes
- (none)

## Discuss-tier resolutions
- push-neuter best-effort (Codex Cat 1 pri 7): Codex flagged that neuter_push/1 returns :ok even when the `git config` calls fail, so create/2 yields {:ok, wt} with push potentially still enabled. Verified INTENTIONAL: neuter_push is documented (worktree.ex:181-189) as defense-in-depth (Task 186) and deliberately best-effort — failing the whole worktree create on a config-command failure would be worse. The failure is Logger.warning'd (line 203), the residual `gh pr create` vector is honestly disclosed in CHANGELOG, and the gap is tracked as task 188. Codex over-flag of a documented design decision; no fix.

## Codex second-opinion
Status: dual-reviewer
Corroborated findings: —
Codex-only (discarded as over-flag): 1 (push-neuter best-effort — by-design, tracked as task 188)
Note: Agent.Settings two-axis record with backward-compatible load_key/3; persist/0 only materializes reviewer_ineligible once a real override exists; extensions.worktreeConfig scoping verified correct against git-config docs.
