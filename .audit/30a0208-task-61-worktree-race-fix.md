---
sha: 30a02084830672f98fa40f81cf3632248891ea66
short_sha: 30a0208
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — well-tested worktree lifecycle fix)
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 61 Codex run worktree disappeared mid-run + cross-wrote into a sibling worktree (Wave 1)

**Original commit:** 30a0208 — `harness: agent delivery — task 61 Codex run worktree disappeared mid-run + cross-wrote into a sibling worktree (Wave 1) (run run-1779853579936-56683177)`
**Author:** harness (Codex delivery)
**Files touched:** 7 (lib/harness/run.ex, lib/harness/run/result.ex, lib/harness/worktree.ex, lib/harness/worktree/sweeper.ex, test/harness/run_test.exs, test/harness/worktree/sweeper_test.exs, test/support/fake_adapter.ex)
**LOC:** +202

## Findings

None of priority. Codex's Task 61 delivery introduces:

- **`.harness-active` marker** alongside the existing `.harness-retained` marker. Written by `Worktree.activate/1` with `active_at` + `owner_os_pid` + `id` + `branch`. Sweeper preserves both retained AND active worktrees.
- **`Worktree.active?/1`** checks marker existence AND that the owning OS pid (`System.pid/0`) is still alive via `kill -0`.
- **`prepare_for_staging/1`** asserts the worktree dir exists, removes the active marker (so `git add -A` doesn't commit it), then runs the rule cleanup.
- **New `{:worktree_missing, path}` error variant** added to `Worktree.error/0` typespec and surfaced in `Result.reason/0` docstring; `Run.commit_worktree/2` settles `:failed` with that reason instead of crashing inside `AgentRules.worktree_root!/1` on `:enoent`.
- **Two regression tests**: a worktree that `mv`s itself aside before commit settles cleanly; a sibling-worktree cross-write is caught (no foreign content lands on `harness/<run-id>`).

Reviewed with two narrow concerns and discarded both:
- **OS pid reuse** between BEAM restarts could falsely register an unrelated process as the worktree's owner. Linux PID space is large enough (2^15+) that the window is narrow; the marker is also one of two reapability signals (the dir must still exist). Acceptable.
- **Marker removed before staging — verification-window unprotected.** Between `commit/2` removing the active marker and `finish/3` running, a BEAM crash would let the sweeper reap the (already-committed) directory. The branch survives though, so the agent's work isn't lost. Acceptable trade-off.

## Auto-applied fixes

— None needed.

## Discuss-tier resolutions

— None.

## Codex second-opinion

Status: not-dispatched. The Codex-delivered diff is small, focused, and carries regression tests that directly prove the original bug (both worktree-vanishes-mid-run AND cross-writes-into-sibling-worktree).
