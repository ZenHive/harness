---
sha: 9f0f8379bcb3cb34477d4b0dd580bdb2cbb9729a
short_sha: 9f0f837
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: findings-noted (2 follow-ups filed as Task 69)
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: worktree.isolation — pollution allowlist (defaults + per-project + per-run + app config) (task 60)

**Original commit:** 9f0f837 — `harness: worktree.isolation — pollution allowlist (defaults + per-project + per-run + app config) (task 60)`
**Author:** E.FU
**Files touched:** 7 (config/config.exs, lib/harness/project.ex, lib/harness/project_registry.ex, lib/harness/run.ex, lib/harness/run/supervisor.ex, lib/harness/worktree/isolation.ex, test/harness/worktree/isolation_test.exs)
**LOC:** +257 / -0 (effectively)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 8 | bug (codex) | lib/harness/worktree/isolation.ex:`porcelain_path/1` | Rename `R old -> new` only allowlists destination; an agent that moves `lib/foo.ex` → `.claude/foo.ex` masks the source-side deletion. | filed as rmap follow-up (Task 69) |
| 2 | 5 | bug (codex) | lib/harness/worktree/isolation.ex:default allowlist | `.DS_Store` is an exact-match pattern; `docs/.DS_Store` still trips pollution. | filed as rmap follow-up (Task 69) |
| 3 | — | acceptance | — | Four-tier resolution (run opts → project → app config → defaults) implemented in `Harness.Run.resolve_pollution_allowlist/2` + `Isolation.pollution_allowlist/1`. ✅ | met |
| 4 | — | acceptance | — | Roadmap files NOT allowlisted (`roadmap/tasks.toml`, `ROADMAP.md`, `roadmap/data.json` deliberately absent). ✅ | met |
| 5 | — | acceptance | — | Defaults cover `.claude/`, `.DS_Store`, `*.swp`, `*.swo`, `*~`, `.#*`, `#*#`. ✅ | met |

## Auto-applied fixes

— None applied (both bug findings are narrow design-decisions about contract semantics; the surgical fix on rename source tracking + recursive-basename matching ships as Task 69).

## Discuss-tier resolutions

— None.

## Codex second-opinion

Status: dual-reviewer (jobId task-mpnox1t0-femb5o).
Corroborated findings: —
Codex-only findings: 1, 2 (both routed to rmap follow-up per Step 5d triage — single-reasoner bug findings file rather than auto-apply).
Codex-only findings (discarded as over-flag): —

Codex verified the roadmap files were absent from the allowlist before flagging the other two — its sandbox refused `mix credo` on TCP `:eperm` but the source-level checks went through.
