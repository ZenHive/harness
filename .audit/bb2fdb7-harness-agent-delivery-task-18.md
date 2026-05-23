---
sha: bb2fdb702cad77939c6cb4762190b539a8c44a16
short_sha: bb2fdb7
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 18 Human status view

**Original commit:** bb2fdb7 — `harness: agent delivery — task 18 Human status view (run run-1779522372230-4b2753a6)`
**Author:** harness (agent: Cursor, delivered via dogfood batch)
**Files touched:** 7 (`lib/harness/agent_registry.ex`, `lib/harness/run.ex`, `lib/harness/run/status.ex`, `lib/harness/status_view.ex` NEW, `lib/mix/tasks/harness.status.ex` NEW, `test/harness/agent_registry_test.exs`, `test/harness/status_view_test.exs` NEW)
**LOC:** +308 / −2

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | 1 bug | lib/mix/tasks/harness.status.ex | `mix harness.status` started fresh sees an empty Registry — no IPC to a running harness BEAM, so the task only works inside the dispatch-loop IEx session | applied: documented same-BEAM constraint in moduledoc (codex finding, verified) |
| 2 | 5 | 6 doc-gap | CHANGELOG.md | `[Unreleased]` missing Task 18 entry (`Harness.StatusView`, `mix harness.status`, `AgentRegistry.list_unavailable/0`, `Run.Status.reason`) | applied: added comprehensive entry (Claude + Codex agreed) |
| 3 | 4 | 1/2 robustness | lib/harness/status_view.ex:95 | `describe_reason/1` had no fallthrough for unknown reason shapes (asymmetric with `describe_unavailable/1` which catches `inspect(reason)`) | dropped: dialyzer rejected the proposed fallthrough as unreachable — `Result.reason()` is a closed sum of atoms + 2-tuples, so the symmetry argument doesn't apply at type level (asymmetry with `describe_unavailable/1` is justified by its `term()` spec) |

## Auto-applied fixes

- `lib/mix/tasks/harness.status.ex` — moduledoc now flags the "same-BEAM only" limitation and points users at the in-IEx invocation (`Harness.StatusView.snapshot/0` / `render/1`) for use from a remote shell.
- `CHANGELOG.md` — added `Harness.StatusView` / `mix harness.status` entry under `### Added`.
- (`describe_reason/1` fallthrough rejected: dialyzer flagged the added clause as unreachable given the closed `Result.reason()` type; the asymmetry with `describe_unavailable/1` is correct because that function's `@spec` is `term()`, not `Result.reason()`. Future widenings of `Result.reason()` to non-atom-non-2-tuple shapes would re-open the question.)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 2 (CHANGELOG gap — Claude + Codex agreed)
Codex-only findings (verified): 1 (`mix harness.status` empty-Registry behaviour — verified against task body + Registry semantics)
Codex-only findings (discarded as over-flag): Codex reported "1 current-HEAD test failed" — re-verified locally as 279/279 passing; Codex's failure was a sandbox `:eperm` artifact, not a real regression.

## Notes

- Codex flagged the empty-Registry case as priority 7. Treated as priority 6 here because the underlying limitation is structural (BEAM IPC absent) rather than a bug; the fix is to document the contract.
