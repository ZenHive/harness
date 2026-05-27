---
sha: 956f5091c9c413d662300fb31c6513eae8b201c2
short_sha: 956f509
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — user directive; agent delivery + adjacent integration fix in 7805edd)
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 49 In-repo <repo>/harness/ subdirectory recipe + template

**Original commit:** 956f509 — agent delivery (Cursor)
**Author:** harness@localhost (worktree)
**Files touched:** 9 (1 lib, 1 docs, 6 priv/template, 1 test)
**LOC:** +486

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | acceptance | — | In-repo `<repo>/harness/` subdirectory recipe documented: ✅ | met |
| 2 | — | acceptance | — | Template scaffold under `priv/templates/in_repo_harness/`: ✅ | met |
| 3 | — | acceptance | — | `Harness.InRepoTemplate` programmatic surface (`dir/0` + `copy!/1`): ✅ | met |

The recipe doc is thorough — when-to-use table, directory layout, gitignore decisions, end-to-end Rust example. The template's `config/runtime.exs` resolves `target_root` via `HARNESS_TARGET_ROOT` env override, which is the right hook for non-default layouts.

The two verification gaps that surfaced (`@doc` missing on `dir/0`; sobelow false-positive on `File.cp_r!`) are closed in the adjacent integration commit `7805edd` — audited in `.audit/7805edd-task-49-doc-sobelow-fixup.md` with a clean verdict.

## Auto-applied fixes

— None (integration fixes already landed in `7805edd`).

## Codex second-opinion

Status: not-dispatched (user-directed tight pass; agent delivery + adjacent integration fix together yielded verification-stack-green state)
