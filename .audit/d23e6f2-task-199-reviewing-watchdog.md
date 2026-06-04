# Audit — d23e6f2 (Task 199: reviewing-phase spawn + idle watchdog)

**Range:** `d297e5a..c44fed3` · **Commit:** d23e6f2 · **Date:** 2026-06-04
**Reviewers:** Claude (primary) + Codex (second opinion, parallel) · **Verdict:** approve-with-fixes (applied inline)

## Context

Salvaged from crashed run `run-1780547458231-66f464e9` (laptop kernel panic mid-review,
reviewer never wrote a verdict). Only the `run.ex` + `run_test.exs` watchdog payload was
landed; the run's stale Chat.Store hunks were dropped (development carries the reconciled
facade). Originally manually gated (diff review + `precommit.full` green) because the
dispatched reviewer never ran — this audit is the deferred cross-family second pass.

## Findings & dispositions

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| 1 | serious | **Reviewer process leak on driver crash.** `reviewing(:info, {ref, {:error, _}})` and the `:DOWN` handler cleared `reviewer_run` but never called `terminate_reviewer/1` — if the reviewer Port had spawned, its OS process leaked. Directly feeds the OOM class Task 200 targets (jetsam killed `beam.smp`). | **FIXED** — `terminate_reviewer(data)` added to both handlers before clearing. |
| 2 | serious→moderate | **Early transcript chunk could cancel the spawn watchdog.** `rearm_reviewing_idle/3` armed the idle `state_timeout` on any `:reviewing` transcript chunk; since gen_statem holds one `state_timeout`, a stray chunk arriving before `{:reviewer_handle, _}` would replace the 60s spawn timer with the (longer) idle window. Guarded in practice by same-process spawn→output message ordering, but fragile. | **FIXED** — `rearm_reviewing_idle/3` now matches only when `reviewer_run` is set (`%AgentRun{}`); before the handle is captured the spawn watchdog keeps the timer. |
| 3 | moderate | **Terminate/teardown ordering race.** `fail_review_stuck/2` ran `cancel_task(data.task)` (the reviewer Port owner) *before* `terminate_reviewer/1`; closing the port first can reap/race the stored `os_pid`. The same cancel→terminate ordering exists in the general cancel/lifetime/`fail` handlers (run.ex ~1041/1072/1102). | **PARTIAL** — reordered in `fail_review_stuck/2` (isolated, clearly the reviewer task). The general handlers share the pattern with `terminate_agent/1` and were left to avoid churning stable teardown for a benign (kill dead/own-pid) race — filed as follow-up. |

Codex confirmed **no** real finding on lost cancel replies: the `:review_stuck` paths aren't reachable with `cancel_requested` set.

## Verification

- `mix compile --warnings-as-errors` clean.
- `test/harness/run_test.exs`: 78 tests, 0 failures (watchdog describe block 7/7).
- Per-edit hook stack (format/credo/dialyzer/sobelow) green on `run.ex`.

## Follow-up filed

- Reorder `terminate_reviewer`/`terminate_agent` before `cancel_task` in the general
  cancel/lifetime/`fail` handlers (finding #3 remainder) — low priority, benign race.
