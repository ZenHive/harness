---
sha: 3250a9faff002c1793358953c2b8a7a04f78e330
short_sha: 3250a9f
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 34 Audit-surfaced: Batch.fill_slots crashes after AgentRegistry exhaustion

**Original commit:** 3250a9f — `harness: agent delivery — task 34 Audit-surfaced: Batch.fill_slots crashes after AgentRegistry exhaustion (run run-1779522372220-6be0341b)`
**Author:** harness (agent: Claude, delivered via dogfood batch)
**Files touched:** 3 (`lib/harness/batch.ex`, `lib/harness/run/result.ex`, `test/harness/batch_test.exs`)
**LOC:** +114 / −15

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | 6 doc-gap | CHANGELOG.md | `[Unreleased]` missing entry for `Batch.fill_slots` fix and `{:no_available_agent, _}` reason | applied: added "Fixed" section + reason-type note (also flagged by codex) |
| 2 | 3 | 6 doc-gap | lib/harness/run/result.ex:63 | `run_id` doc says "worktree id and branch suffix" — false for synthetic `undispatched-*` ids | applied: amended docstring to disclose synthetic id path (codex-only finding, verified against source) |
| 3 | 3 | 3 todo | lib/harness/batch.ex:206 | Sibling `start_run/4` pattern match — `{:ok, run_id, pid} = ...` — has no `TODO(Task 35)` marker for the documented race | applied: added inline `TODO(Task 35): ...` comment (codex-only finding, verified) |

## Auto-applied fixes

- `CHANGELOG.md` — added `### Fixed` section under `[Unreleased]` describing the `fill_slots` no-crash behavior and the new `{:no_available_agent, term()}` reason variant.
- `lib/harness/run/result.ex:63` — expanded `run_id` field doc to disclose that `{:no_available_agent, _}` settlements carry synthetic `undispatched-<task-id>-<n>` ids with no worktree or branch.
- `lib/harness/batch.ex:206` — added `# TODO(Task 35): ...` comment above the remaining unsafe `{:ok, run_id, pid} = RunSupervisor.start_run(...)` pattern match, the known-open companion race.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (CHANGELOG gap — Claude + Codex agreed)
Codex-only findings (verified): 2 (`run_id` doc drift), 3 (`TODO(Task 35)` marker)
Codex-only findings (discarded as over-flag): —
Codex notes: `mix dialyzer.json` and `mix credo` were unable to run in Codex's sandbox (Mix PubSub `:eperm`); offline test suite 279/279 passed in its session.
