# Audit report for ceef7a7 (task 286 dispatch in-flight idempotency)

**Range audited (landed, already merged to development):**
- ceef7a7 `roadmap: task 286 -> done (shipped cdd7fbace888)`
- cdd7fba `review(task 286): harden idempotency test timeout and dedupe unique_opts helper`
- 329647f `harness: agent delivery — task 286 Dispatch in-flight idempotency: a second dispatch of {project, task_id} with a non-terminal run must return the existing run, not spawn a duplicate (run run-1781435587994-2492d30b)`
- e60d349 `roadmap: task 286 -> in_progress`
- 6449e47 `roadmap: task 286 — dispatch in-flight idempotency guard (verified ccxt_extract/146 double-dispatch)`

**Previous audit marker:** 5c68366 (task 285 range).

## What was reviewed
- All code diffs in the delivery commit (329647f) + review fix (cdd7fba): `lib/harness/run/worker.ex`, `lib/harness/batch.ex`, `lib/harness/cron/roadmap_poller.ex`, `test/harness/batch_test.exs`, `test/harness/oban_dispatch_test.exs`.
- Git history and commit messages for context.
- CHANGELOG.md (Unreleased section) for coverage of the landed change.
- Canonical driver surface `skills/harness-driver/SKILL.md` and `lib/harness/dispatch.ex` (dispatch contract surface) for staleness on the new enqueue behavior.
- Surrounding code, naming, @spec/@doc, removed helpers, test updates, and cross-references (no roadmap/ files touched).
- Project conventions (Elixir specs on all new fns including defp, terse comments only where needed, no bare TODOs, functional style).
- The supplied reviewer-quality note (task 208 coverage rejection from a prior range).

## Findings (2)
1. **CHANGELOG gap.** Task 286 is a material behavioral change to the core dispatch contract (idempotency at the Oban enqueue boundary for in-flight {project, item} pairs). Prior tasks 283/284/285 have detailed Unreleased entries; 286 had none. This is the primary hygiene item for post-merge audits on agent deliveries.
2. **Thin public documentation of observable contract change.** `Harness.Run.Worker.enqueue/4` @doc was the one-line "Enqueues a restart-resilient run worker job and returns the run id it will use." The new idempotent return-existing-run path (the whole point of the task, and now visible to every `dispatch-task` / Batch / poller caller) was not reflected in the public surface doc. Driver skill descriptions of dispatch-task/bundle were not updated (high-level "returns a run_id"; the new behavior makes blind retries safe and returns the live handle, which is an improvement but worth a note for consumers).

No other issues found:
- No dead code, no leftover debug prints or commented-out blocks.
- Removed code was cleanly excised (`@unique_opts` + `put_env/2` from poller; local `unique_opts/0` helper from oban_dispatch_test — review commit deduped calls to the new public `Worker.unique_opts()`).
- Naming consistent (mirrors `Audit.Worker.unique_opts/0`; `new_dispatch_job/4` is the obvious centralizer; private helpers are clearly named with @spec).
- All new/changed public and internal fns carry `@spec`; new public helper is explicitly `@doc false`.
- Tests: the new batch uniqueness assertion and the two oban_dispatch describe blocks cover the contract (executing duplicate → same run/job/conflict?, terminal prior allows fresh, orphan-rescue paths updated to public helper). The review commit's timeout bump (30s → 60s) and comment cleanup were appropriate.
- No convention violations (no `@tag :skip`, no credo disables added, no IO in docs, doctests remain happy-path only).
- Dispatch callers in `dispatch.ex` (enqueue_start) and poller/batch transparently benefit; no signature or error-path changes for healthy cases.
- Roadmap markers and data.json left untouched (per operational rules).
- The supplied prior reviewer rejection (task 208, coverage 79.47% < 80% on precommit.full) is from an earlier range and unrelated to this batch; the 286 work landed cleanly with reviewer approval and no equivalent false-negative signal here.

## Fixes applied (2)
1. Added a concise but complete entry under `## [Unreleased] ### Fixed` describing the guard, the centralization, test coverage, the review hardening, and the motivating double-dispatch observation.
2. Expanded the `@doc` on `enqueue/4` (the sole public entry point) to explicitly call out the in-flight idempotency contract, the conflict? return shape, and the terminal-does-not-block rule. (This makes the behavior self-documenting at the source for future readers and agent consumers.)

No driver skill or other doc edits — the surface descriptions remain accurate at the "returns run_id" level, and the improvement (safer re-dispatch) is now captured in the canonical changelog + the Worker moduledoc-adjacent docstring. Further elaboration in the harness-driver skill would be additive polish, not required hygiene for this narrow range.

## Checks
- Edits touched source (`lib/harness/run/worker.ex`) + docs, so `mix precommit.full` was run (backgrounded; see harness logs for full output). Per prior audit patterns and CLAUDE.md guidance, full suite is the right gate when source is touched.
- No discoveries filed via `rmap new` — the only gap was standard CHANGELOG hygiene fixed inline by the audit. No new tech debt, orphaned path, or deferred decision surfaced that rose to separate roadmap task.

## Outcome
Range was sound. The implementation followed the mantra (count in code via Oban's unique + conflict?, judgment stays with orchestrator/agents), used existing Oban machinery, centralized to prevent drift, and the review pass improved the test. Audit performed the expected post-merge hygiene (CHANGELOG + observable doc) and produced this marker commit.

**No reverts, no blocks, fixes-forward only.**
