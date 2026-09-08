# Task 421 follow-up (PR3 / ec761bd close-out) — Independent Review

**Verdict: APPROVE.** All three defects from the prior round are fixed, the new tests are real
regression guards that fail on the pre-patch code, my one recorded non-blocking defect is now
closed, and every gate I ran on the final staged patch is green.

Reviewer: independent evaluator (Cursor / `claude-opus-5-high`), read-only on source — I made
**no source, test, roadmap, or doc edits** at any point.
Checkout: `/data/postgresql/harness/cache-preparation`, branch `feat/project-cache-preparation`.
Graded: 2026-09-08 03:37–03:50 UTC against the final staged patch (`git diff HEAD`): 6 files,
218 insertions / 24 deletions.

This supersedes my 03:43 reject, which was blocked solely on two credo `--strict` nesting
findings in the patch's own hunks.

---

## 1. Evidence (all on the final staged bytes)

| Check | Artifact | Result |
|---|---|---|
| `mix check.dispatch` | `/tmp/cc-gate3.log` | **exit 0** — format, `compile --warnings-as-errors`, `credo --strict` ("5821 mods/funs, found no issues"), Doctor (100.0% doc / moduledoc / spec, "validation has passed"), Sobelow ("SCAN COMPLETE") |
| `mix dialyzer.json` | `/tmp/cc-dialyzer3.log` | **exit 0** — `"warnings": []`, `total: 0`, `skipped: 0`; PLT up to date, `.dialyzer_ignore.exs` in effect |
| Focused suite, 5 files, `--no-retry` | `/tmp/cc-tests3.json` | **96 passed, 0 failed**, 0 excluded, exit 0, 26.3 s |

Earlier artifacts, retained for the audit trail: `/tmp/cache-close-check-dispatch.log` (exit 8,
the two nesting findings that blocked at 03:43), `/tmp/cache-close-check-dispatch-2.log` (exit 0
after the extractions), `/tmp/cache-close-review-focused.json` and
`/tmp/cache-close-final-focused.json` (96/0 both), `/tmp/cache-close-new-only.json` (10/0), and
the operator run `/tmp/cache-close-focused.json` (124/0, 1 excluded).

Two details that make the counts load-bearing rather than decorative. The `mix test.json`
artifacts are `--quiet` (summary-only, `tests: []`) by design, so per-test names are not
recoverable from them; the new-coverage-only run resolves that by arithmetic — 10 collected =
`copy_cancellation_test.exs` 3 (the `for` loop over `:remove` / `:retain` / `:crash_cleanup`) +
`command_test.exs` 7 (6 pre-existing + 1 new startup test), so all three lock-serialization cases
and the new startup test were genuinely collected and passed. And the focused total held at
exactly 96 across the pre-extraction, post-extraction, and post-`:aborted`-fix runs, which
confirms neither follow-up edit changed test collection or behavior.

Credo's function count rising 5819 → 5821 accounts for exactly the two extracted privates, and
Doctor holding 100% spec coverage confirms both carry specs.

## 2. What the patch gets right

1. **`await_start` cancellation and the deadline floor.** The `{:DOWN, ^owner, …}` clause is
   present and `max(remaining(deadline), 1000)` is now plain `remaining(deadline)`, so the
   per-iteration re-arm I flagged — a chatty pre-marker stream re-arming 1000 ms indefinitely
   through the `started/4` → `await_start/4` recursion — is gone.
2. **The new startup test is a genuine regression guard, not a tautology.** It shims `setsid` on
   `PATH` with a script that signals ready then blocks on a FIFO, so the PGID marker never
   arrives. Both modes fail on the pre-patch code against `Task.await(task, 500)`: `:timeout`
   with a 100 ms budget would have waited the old 1000 ms floor, and `:cancel` with a 5000 ms
   budget would have waited the full budget for want of a DOWN clause.
3. **The permit handshake closes the orphaned-command class.** `IFS= read -r permit || exit`
   before `exec`, with `Port.command(port, "go\n")` gated behind `check(owner, deadline)`, means
   the user command cannot exec after cancellation or deadline expiry. Both exits are covered:
   `stop_group/2` SIGKILLs the session when the marker was parsed, and on the start-path failures
   `OSProcess.close(port)` gives the still-blocked wrapper stdin EOF so it exits without
   exec'ing. The added `sigkill(os_pid)` on `:timeout` / `:interrupted` reaps the `setsid --wait`
   parent, which SIGKILL alone would not reach through to the wrapper. This also removes the
   hazard I raised previously, where dropping the floor *without* the handshake would have made
   start-timeout orphans more likely.
4. **`on_exit` env restores.** Added in all four env-mutating tests. This matters because on an
   ExUnit test timeout the runner calls `Process.exit(test_pid, :kill)`
   (`ExUnit.Runner.receive_test_reply/4`, Elixir 1.20.3), which skips `try/after` but still runs
   `on_exit` via `exec_on_exit/3` — so a timeout in the `PATH=/nonexistent` window can no longer
   strand a broken `PATH` across the rest of the run.
5. **`with_write_lock` serialization is real and tested on all three finalization paths.** The
   new test holds an in-worktree `cp` at a FIFO barrier (shimming `cp` and matching only
   `*cache-seed-*`, so the build-phase copy into `<cache>/<key>.building-*` is deliberately not
   blocked), brutal-kills the caller, then asserts finalization does not complete
   (`refute_receive {^ref, _}, 100`) and does complete after release, leaving no `deps`, no
   `.harness/cache-seed-*`, and no `*.building-*`. The `:crash_cleanup` case passing is also
   incidental evidence that the two lock keys agree on this host: the worker locks
   `worktree.path` while `cleanup_for_run/2` locks the path parsed from `git worktree list
   --porcelain`, and a mismatch would have let finalization through immediately and failed the
   `refute_receive`.
6. **The two extractions are behavior-preserving.** `execute_owned/5` and `finish_failure/2` each
   lift an existing branch into a named private with a `@spec` — same conditions, same return
   values, still evaluated inside the lock. Confirmed by reading the diff and by the unchanged
   96-test result.
7. **`:aborted` is now handled, mirroring the module's own precedent.** `with_write_lock/2` wraps
   `:global.trans/3` in `case … do :aborted -> {:error, {:worktree_lock_aborted, path}}; result ->
   result end`, exactly the shape `locked_worktree_add/2` already uses, and
   `{:worktree_lock_aborted, String.t()}` was already a member of `t:error/0`. So `finish/3`'s and
   `remove/1`'s `:ok | {:error, error()}` contracts are accurate again, and
   `Settlement.finish_worktree/2`'s `{:error, reason}` branch catches the case that would
   otherwise have raised `CaseClauseError` inside `settle/2` in the gen_statem's terminal `:enter`
   handler. The widened spec (`result | {:error, error()} when result: var`) type-checks — dialyzer
   is clean at 0 warnings.

## 3. Positions I withdrew or corrected during the review

- **Generation cancellation semantics — withdrawn.** The operator explicitly requires interrupted
  builders not to publish; the pre-`rename` `Command.check/2` implements that, and my earlier
  suggestion to publish the finished generation is void.
- **"Up to 30 minutes of gen_statem stall" — corrected.** With the handshake and the
  pre-`Port.command` check, no new command starts after cancellation, so `recipe["timeout_ms"]`
  (1,800,000 ms default) no longer bounds the lock hold. The residual hold is one in-flight
  non-`Command` operation — the `git clone` / `git checkout`, the `publishable` `lstat` walk, or
  the `cp -R` — seconds to tens of seconds, and the new test asserts that wait deliberately. That
  is a design trade chosen over the race; I raised it once and it is the operator's call, so it
  forms no part of this verdict.

## 4. Scope — what I did not do

- No source, test, roadmap, or doc edits; read-only throughout.
- No full suite and no `mix precommit.full`; no live service, no foreign worktrees, no unrelated
  processes or config. I inspected no baseline outside the two credo findings, both of which were
  in the patch and are now cleared.
- `docs/project-cache.md` (1 line) not independently diffed — two `git diff` invocations for that
  path returned empty output on a flaky shell, and it is a doc line with no bearing on the verdict.

## 5. Bottom line

Behavior was already right at 03:43. The credo blocker is cleared by two behavior-preserving
extractions, and the `:aborted` contract gap is closed against the module's own precedent.
`mix check.dispatch` exits 0 with credo, Doctor, and Sobelow clean; `mix dialyzer.json` reports
zero warnings; the focused suite is 96/96 with zero failures on the final staged bytes.

**Approve. Ready to commit.**
