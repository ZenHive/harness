---
sha: 8793f0cba99931ebb955346f48a3428f7373810b
short_sha: 8793f0c
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — user directive; agent delivery graded by harness verification stack)
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 47 GitHub project sources + clone-and-cache

**Original commit:** 8793f0c — agent delivery (Claude 1M)
**Author:** E.FU (integration commit)
**Files touched:** 13 (6 lib, 5 test, 1 fixture, CHANGELOG)
**LOC:** +618 / -7

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | acceptance | — | `{:github, url}` clone-and-cache via Github source: ✅ | met |
| 2 | — | acceptance | — | `git fetch` + fast-forward before each run; transparent re-clone on cache loss: ✅ | met |
| 3 | — | acceptance | — | Cache root resolution (opt > config > default ~/_DATA/harness/projects): ✅ | met |

Notable correct shapes:

- `local_path/2` is pure and documented as such; `ensure_local/2` carries the side effects. Clean separation.
- Fast-forward via `git update-ref refs/heads/<branch> refs/remotes/origin/<branch>` (with inline comment explaining why — `git worktree add` would carve from a stale local ref otherwise). This is exactly the right shape for the post-fetch race.
- `Worktree.error/0` extended with `{:source_unavailable, term()}` wrapping clone/fetch failures — clean error layering keeps the public type self-describing.
- `sobelow_skip ["Traversal.FileModule"]` on `clone/2` carries a comment explaining the path is harness-owned (cache_root + name validated upstream). Matches the convention used elsewhere.
- ProjectRegistry `fetch_source/1` extended with the `{:github, url}` arm; rejects malformed shapes with `{:invalid_project, {:unsupported_source, other}}`.

Verification post-integration: 457/457 offline + 9/9 integration tests pass, 0 dialyzer warnings (per commit body).

## Auto-applied fixes

— None.

## Codex second-opinion

Status: not-dispatched (user-directed tight pass; agent delivery already graded by harness verification stack + integration tests)
