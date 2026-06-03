---
sha: 5d1d6913bc2e55b7441bbfa1f187bd264d32a5ab
short_sha: 5d1d691
audited_at: 2026-06-03
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: liveness guard for cleanup_for_run + duplicate re-attempt cancel (job-118 live-worktree-destruction fix)

**Original commit:** 5d1d691 — `harness: liveness guard for cleanup_for_run + duplicate re-attempt cancel (job-118 live-worktree-destruction fix)`
**Author:** E.FU
**Files touched:** 6 (worker.ex, worktree.ex, 2 test files + roadmap render pair)
**LOC:** +181 / −4

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6   | design   | lib/harness/worktree.ex:443 | Refused cleanup on a live run that later crashes leaks worktree+branch until boot (no same-BEAM reaper) | Recorded as follow-up (not filed — see note) |
| 2 | 5   | design   | lib/harness/oban.ex:149      | `rescue_orphaned_run_jobs/0` is all-or-nothing: any live run blocks rescuing unrelated orphaned `executing` jobs; runs once at boot | Recorded as follow-up (not filed — see note) |

## Summary

The fix is correct and strictly safer than the bug it closes (a retry's cleanup destroying a live run's worktree mid-review). Both reviewers confirmed the diff has **no bugs**:

- **Guard completeness:** `duplicate_cancel_reason/1`'s single clause is only reached after `duplicate_run_reason?/1` matches the same `{:start_run_failed, {:already_started, pid}}` shape — no `FunctionClauseError` path.
- **TOCTOU:** a window exists between `live_run?/1` and `do_cleanup_for_run/2`, but it's acceptable given call sites — normal cleanup only follows `{:start_run_failed, _}`, and the Oban boot rescue refuses while any run is registered.
- **Registry semantics:** `Harness.Run.Registry` is `keys: :unique`; `Registry.lookup/2` returns `[]` for absent / `[{pid, _}]` for live — the `Process.whereis` nil-guard handles a bare unit boot.
- Both new tests (`worktree_test.exs` live-vs-dead cleanup, `oban_dispatch_test.exs` duplicate-cancel) are well-isolated (GitFixture temp repos / spawned live pids).

## Auto-applied fixes

- (none — no bugs in the diff)

## Discuss-tier resolutions

The two findings are **verified design follow-ups**, not defects in the committed diff — they are consequences the liveness guard creates by trading a catastrophic failure (destroying a live worktree) for a recoverable one (a leaked worktree reaped at next boot via `Harness.Worktree.Sweeper`). Both are mechanical-substrate concerns the agent-gate explicitly owns:

1. **Post-refusal leak** — a refused-then-crashed run finishes via the worker's crashed-result path (`run/worker.ex:192-201`) without `finish_worktree/2`; only the boot-time sweeper reclaims it. A same-BEAM `Run.Registry` `:DOWN` reaper would close the gap within the node's lifetime.
2. **All-or-nothing orphan rescue** — per-job liveness instead of refusing the whole rescue would let unrelated orphans recover while one run is live.

**Not filed as an rmap task in this audit commit:** the roadmap files (`tasks.toml`, `data.json`, `ROADMAP.md`) carried pre-existing *uncommitted* work (a draft task 184 from another session) when the audit ran. Filing via `rmap new` would re-render those files and entangle task 184 into the `audit(...)` commit. Surfaced in the audit summary instead — the user should `rmap new` these two follow-ups (suggest phase 16 / bundle `agent-gate` / milestone `v0_12`, audit-estimate D3/B4/U4) once task 184 is committed.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: — (the two design findings are Codex-surfaced, Claude-verified against cited line numbers)
Codex-only findings (verified): 1, 2 (both confirmed real by reading the cited code paths)
Codex-only findings (discarded as over-flag): —
Note: Codex could not run the test suite in its sandbox (writable-tmp `:eperm` from config/config.exs:180); findings are read-based and line-cited. Claude confirmed the sweeper-is-boot-only and rescue-all-or-nothing claims against the actual modules.
