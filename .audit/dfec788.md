# Audit dfec788 (Task 227 substrate retry)

**Range audited (already landed on development):**
- dfec788: `roadmap: task 227 -> done (shipped 3739c54e6b76)`
- 3739c54: `harness: agent delivery — task 227 Tier-1: bounded mechanical retry on transient substrate ops (worktree git + agent Port spawn) (run run-1780710369439-c5c72672)`

## Scope of review
- Full diff of the delivery commit (lib/harness/run.ex, lib/harness/worktree.ex, lib/harness/run/retry_policy.ex, test/harness/run_test.exs, test/harness/worktree_test.exs).
- Current on-disk state of the modified modules after landing.
- CHANGELOG coverage for the delivered capability.
- Project conventions: `@spec` on every function, concise `@moduledoc`/`@doc`, no bare TODOs, useful (non-trivial) tests, mechanical substrate only (per agent-gate mantra), no English-string classifiers or semantic gates in harness code.
- Cross-check against CLAUDE.md mandates for this repo (library-first, judgment lives in agents, count facts in code).
- Prior audit patterns in `.audit/*.md` for changelog-fill and "range otherwise clean" reporting.
- No reviewer rejections recorded for this project in the audit prompt (nothing to surface as potential false rejection).

## Findings

### Actionable hygiene (fixed)
- **CHANGELOG gap.** The Task 227 delivery had no entry under `## [Unreleased] / ### Added`. Recent audits (e.g. 4d6f040 for Task 236, 89e5c61 for 228/233, d4fc6db for 209) routinely supply missing entries for agent deliveries that focused on the code + tests. Added a crisp, style-matched bullet under `### Added` describing the bounded mechanical retry surface, the policy module, the double-retry suppression, the witness contract, and the "no classifiers" invariant.

### Notes (no action)
- **Namespace placement.** `Harness.Run.RetryPolicy` is defined under `Run` but consumed by `Harness.Worktree` (aliased at the top of worktree.ex). This is a minor cross-cutting smell. Defensible in context: the policy governs per-run substrate behavior during a `Harness.Run` lifecycle; Worktree is a called substrate. Not promoted to a top-level `Harness.RetryPolicy` in this hygiene pass — that would be scope expansion beyond "fix forward what you find."
- **Tiny duplicate wrapper.** `retry_substrate/2` + `do_retry_substrate/3` are implemented in both run.ex and worktree.ex. Both are thin (construct policy from opts, delegate to the shared `RetryPolicy` arithmetic). The design keeps the two call sites (Run's driver/fetch/commit path, Worktree's create/commit path) from depending on a new internal shared module during early Tier-1 rollout. The source-grep test ("mechanical retry does not add git error-string classifiers") in worktree_test.exs directly enforces the key contract that retry stays purely mechanical. Acceptable; noted for future consolidation if the surface grows.
- Everything else clean:
  - No dead code, no debug `IO.puts`/`Logger` left behind, no bare `TODO`, no `# credo:disable` without a mantra comment.
  - All new functions carry `@spec` (public `create/2`/`commit/3` updates, the private `run_driver`/`fetch_target`/`commit_worktree` wrappers, and the two private retry helpers). `RetryPolicy.new/1` and `backoff_ms/2` have one-line `@doc` + `@spec`; the private `fetch/4` correctly has only `@spec`.
  - `Worktree.commit/3` uses the documented two-head form with `@spec` on the primary head — matches existing style in the file.
  - New tests are useful: transient spawn failure, transient ref/index lock during create/commit, persistent failure after bound, and the source-invariant classifier prohibition. They cover the boundary the task asked for (Tier-1 mechanical retry on substrate) without trivial happy-path assertions.
  - `commit_worktree` in Run correctly passes `substrate_retry: [max_retries: 0]` to the inner `Worktree.commit` to avoid double backoff on the (diff_size + commit) compound — the comment in the diff makes the intent explicit.
  - The roadmap marker commit (dfec788) only touched `roadmap/tasks.toml` + `roadmap/data.json` — correct harness bookkeeping, no implementer touching the roadmap.

## Fixes applied
- CHANGELOG.md: inserted Task 227 entry under `### Added` (immediately before the Task 233 cron-orchestrator entry for chronological grouping with other recent mechanical substrate work).

## Outcome
The landed range is otherwise clean. The delivery is a minimal, faithful implementation of "bounded mechanical retry on transient substrate ops" with clear separation of counting (harness retry arithmetic + witness facts) from judgment (the cross-family reviewer AI remains THE gate). No reverts, no blocks, no scope expansion.

**Findings:** 1 (the changelog gap)  
**Fixed:** 1

(Reviewer-quality feedback loop: no rejections recorded for this project; nothing to note as potential false rejection.)
