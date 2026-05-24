---
sha: 94f70f4
short_sha: 94f70f4
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 36 Audit-surfaced: Harness-injected rule files get committed by Worktree.commit

**Original commit:** 94f70f4 — Task 36 delivery (Codex)
**Files touched:** 2 lib/ + tests + docs (193 LOC)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | leaked artifact (resolved) | AGENTS.md (committed at this SHA) | Commit ironically committed the harness-injected `AGENTS.md` itself — the exact leak Task 36 is meant to prevent | Resolved upstream: file removed by 95fe425 (drop pre-fix rule files) and Task 36's `cleanup_injected_rules/1` prevents future leaks. No action on this commit. |
| 2 | 6 | sobelow false positive (resolved) | lib/harness/agent_rules.ex:176,249,259 | New `File.*` cleanup calls are path-disciplined (via `worktree_file!/2`) but missing `sobelow_skip` annotations would trigger `Traversal.FileModule` false positives in the verification preset | Resolved by 015869f closeout commit, which added the `sobelow_skip ["Traversal.FileModule"]` annotations. No action. |
| 3 | 6 | doc-gap | ROADMAP.md (Task 36 row at 94f70f4); CHANGELOG.md | Status not flipped at delivery commit; no CHANGELOG entry | Historical (agent-delivery / closeout pattern). CHANGELOG.md Task 36 entry already present (line 201, pre-audit). No action. |

## Auto-applied fixes

- (none — all findings resolved by later commits in this audit range)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mpjai21i-51xa5h`).
