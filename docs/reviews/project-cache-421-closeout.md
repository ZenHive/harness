# Task 421 follow-up (PR3 / ec761bd close-out) — Independent Review

**Verdict: APPROVE.** The three defects from the prior round are correctly fixed, the new tests
are real regression guards that fail on the pre-patch code, and the repo's dispatch gate plus the
focused suite are green on the final staged patch.

Reviewer: independent evaluator (Cursor / `claude-opus-5-high`), read-only on source — I made
**no source, test, roadmap, or doc edits** at any point.
Checkout: `/data/postgresql/harness/cache-preparation`, branch `feat/project-cache-preparation`.
Graded: 2026-09-08 03:37–03:47 UTC against the staged patch (`git diff HEAD`), 6 files.

This supersedes my 03:43 reject, which was blocked solely on two credo `--strict` nesting
findings in the patch's own hunks. Both are now cleared by the `execute_owned/5` /
`finish_failure/2` extractions, verified behavior-preserving by reading the diff: each lifts an
existing branch into a named private with a `@spec`, same conditions, same return values, still
evaluated inside the lock.

---

## 1. Evidence

| Check | Artifact | Result |
|---|---|---|
| `mix check.dispatch` (final) | `/tmp/cache-close-check-dispatch-2.log` | **exit 0** — format, `compile --warnings-as-errors`, `credo --strict` ("5821 mods/funs, found no issues"), Doctor (100.0% doc / moduledoc / spec, "validation has passed"), Sobelow ("SCAN COMPLETE") |
| Focused suite, final patch, 5 files `--no-retry` | `/tmp/cache-close-final-focused.json` | **96 passed, 0 failed**, 0 excluded, exit 0, 25.7 s |
| `mix check.dispatch` (pre-extraction) | `/tmp/cache-close-check-dispatch.log` | exit 8 — the two nesting findings, now fixed |
| Focused suite, pre-extraction (mine) | `/tmp/cache-close-review-focused.json` | 96 passed, 0 failed, 25.9 s |
| New-coverage files only, pre-extraction | `/tmp/cache-close-new-only.json` | 10 passed, 0 failed, 1.56 s |
| Focused suite (operator run) | `/tmp/cache-close-focused.json` | 124 passed, 0 failed, 1 excluded, 26.4 s |

The final focused run's 96 total is identical to the pre-extraction run's 96, which confirms the
extraction changed neither test collection nor behavior; 0 failures across 96 means the new cases
pass post-extraction. Both JSON artifacts are `--quiet` (summary-only, `tests: []`) by design, so
per-test names are not recoverable from them; the new-coverage run resolves that by arithmetic
instead — 10 collected = `copy_cancellation_test.exs` 3 (the `for` loop over `:remove` /
`:retain` / `:crash_cleanup`) + `command_test.exs` 7 (6 pre-existing + 1 new startup test), so
all three lock-serialization cases and the new startup test were genuinely collected and passed.

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

Withdrawn from my prior round: **generation cancellation semantics.** The operator explicitly
requires interrupted builders not to publish; the pre-`rename` `Command.check/2` implements that,
and my suggestion to publish the finished generation is void.

Corrected from my prior round: my "up to 30 minutes of gen_statem stall" figure does not apply.
With the handshake and the pre-`Port.command` check, no new command starts after cancellation, so
`recipe["timeout_ms"]` (1,800,000 ms default) no longer bounds the lock hold. The residual hold is
one in-flight non-`Command` operation — the `git clone` / `git checkout`, the `publishable`
`lstat` walk, or the `cp -R` — seconds to tens of seconds, and the new test asserts that wait
deliberately. That is a design trade chosen over the race; I raised it once and it is the
operator's call, so it forms no part of this verdict.

## 3. One non-blocking defect, recorded not fixed (operator declined further edits)

`:global.trans/3` is specced `Res | aborted` by OTP, and `with_write_lock/2` neither handles nor
declares that:

- `@spec with_write_lock(String.t(), (-> result)) :: result when result: var` claims the return is
  exactly the fun's return, and `finish/3` / `remove/1` / `finish_failure/2` keep
  `:ok | {:error, error()}`.
- `Settlement.finish_worktree/2` matches only `:ok` and `{:error, reason}`, so an `:aborted` would
  raise `CaseClauseError` inside `settle/2` — in the gen_statem's `:failed` / `:done` `:enter`
  handler, i.e. a run crash at settle.
- The module already treats this as reachable elsewhere: `locked_worktree_add/2` matches
  `:aborted -> {:error, {:worktree_lock_aborted, repo}}`, and `t:error/0` carries a
  `{:worktree_lock_aborted, String.t()}` member for exactly this.

Not reachable on the deployment target — `trans/3` defaults `Retries` to `infinity` and `Nodes` is
`[node()]`, so `set_lock` loops until acquired rather than returning `false`. Cheapest consistent
fix, whenever this file is next touched, is to mirror the existing `locked_worktree_add/2` shape
inside `with_write_lock/2`.

## 4. Scope — what I did not do

- No source, test, roadmap, or doc edits; read-only throughout.
- No full suite, no `mix precommit.full`, no live service, no foreign worktrees, no unrelated
  processes or config. I inspected no baseline outside the two credo findings, both of which were
  in the patch and are now cleared.
- `mix dialyzer.json` not run. It is the one gate that would most likely speak to §3's contract,
  and it is not part of `check.dispatch`; §3 is unreachable on this target, so this does not
  affect the verdict. Worth taking on the next `precommit.full` pass.
- `docs/project-cache.md` (1 line) not independently diffed — two `git diff` invocations for that
  path returned empty output on a flaky shell, and it is a doc line with no bearing on the verdict.

## 5. Bottom line

Behavior was already right at 03:43; the only blocker was a red dispatch gate from two credo
nesting findings in the patch's own hunks, and the two extractions clear them without touching
behavior. `mix check.dispatch` exits 0 with credo, Doctor, and Sobelow all clean, and the focused
suite is 96/96 with zero failures on the final staged patch.

**Approve. Ready to commit.**
