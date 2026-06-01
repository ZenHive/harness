# Run Recovery — hold / steer / co-drive design

Status: **spec, not yet built.** Authored in a UI/operator session for the orchestrator
session (or a dispatch) to execute. The backend (`Harness.Run` gen_statem) is a
harness-surface change and belongs to the dispatch flow; the dashboard affordance is
operator-facing UI and can be hand-built once the API below exists.

## Problem

An operator watching the dashboard sees a run struggling — wandering, stuck mid-repair,
about to exhaust its attempts and settle `:failed` — and wants to *help it recover*
rather than let it fail and re-dispatch from scratch. Today the only mid-run control is
`Harness.Run.cancel/1`, which kills the agent and settles `:failed` (`run.ex:883-892`).
There is no "freeze this for a human, then continue" path.

## The hard constraint — no live mid-flight steering

Every agent is spawned through `/bin/sh -c 'exec "$0" "$@" </dev/null'`
(`agent_adapter.ex:79,363-371`): stdin gets an immediate EOF on purpose, because headless
CLIs stall on an open empty pipe. **You cannot write steering text into a running agent's
stdin.** Any operator input must land at a *transition boundary* (between attempts), never
during a live attempt. Switching to streaming-input mode (`claude --input-format
stream-json`) was evaluated and rejected: it re-architects the deliberately-EOF'd spawn,
only some adapters support it, and breaks raw-passthrough. Out of scope.

## The two recovery channels we DO have

1. **The worktree filesystem survives a stuck/failed run.** `Worktree.finish(_, :failure, _)`
   retains the directory by default (`worktree.ex:334-337`). Branch `harness/<id>` and the
   agent's partial work are on disk, inspectable and editable.
2. **Resume is cwd-keyed.** Claude's `--continue` reloads the latest conversation *in the
   worktree dir* (`claude.ex:26-33`); grok's session log is keyed the same way. Re-entering
   the same worktree continues the same conversation — no session token needed.

The repair loop already exercises both: on a red verdict it re-enters `:running`, which
calls `build_invocation/1` to resume the same agent (`session: :resume`) in the same
worktree with a feedback prompt (`run.ex:477-492,664-672,1169-1175`). Recovery rides this
exact path; the only new trigger is an operator instead of the grader.

---

## Solution 1 — `hold` / `steer` / `resume` (backend, `Harness.Run`)

### New state: `:held`

A parked state reachable from a live run. While held:
- the lifetime timer is **suspended** — `{{:timeout, :lifetime}, :infinity, :lifetime}`
  cancels the pending fire (`run.ex:415,867`); re-armed on `resume`. The Task 112
  progress-stall watchdog does not run (no live agent in `:held`).
- the worktree is **retained** (teardown only happens at settle; `:held` is not a settle).
- a `max_hold_timeout` safeguard (config, default e.g. 30 min, `:infinity` to disable)
  arms a `{:state_timeout, :held_expired}` so a forgotten hold can't leak a worktree
  forever — on expiry it settles `:failed` with reason `:hold_expired`.

### API (add next to `cancel/1`, same `:gen_statem.call` + `descripex` `api(...)` pattern)

- `hold/1` — park the run.
  - From `:running` with a live agent: **graceful by default** — set a `hold_requested`
    flag; at the next settle boundary (`run.ex:536-545` outcome handling), transition to
    `:held` instead of advancing/tearing down. The agent finishes its current attempt.
  - `hold/2` with `interrupt: true`: kill the agent now (mirror `do_cancel/3`'s
    `terminate_agent/1`) and go straight to `:held` — for a clearly-wandering agent. Costs
    the in-flight attempt; conversation continuity survives via `--continue`.
  - From `:held`: no-op `:ok`. From `:done`/`:failed`: `{:error, :terminal}`.
- `steer/2` — `steer(run, text)`: stash operator guidance. Sets
  `data.operator_feedback = text` and `repair_prompt_kind: :operator_steer`. Callable while
  `:held` (the normal case) or while `:running` (queues for the next boundary). Idempotent
  overwrite — last steer wins, or append; pick append so multiple notes accumulate.
- `resume/1` — from `:held`, `{:next_state, :running, data}`. Re-entering `:running` spawns
  a fresh agent via `build_invocation/1`; the new `:operator_steer` clause makes it resume
  the same conversation in the same worktree with the operator's note as the prompt.
  Re-arms the lifetime timer. From any non-held state: `{:error, :not_held}`.

### Injection point — new `build_invocation/1` clause (`run.ex:1160-1175`)

```elixir
defp build_invocation(%{repair_prompt_kind: :operator_steer} = data) do
  invocation(data, operator_steer_prompt(data), :resume)
end
```
`operator_steer_prompt/1` wraps `data.operator_feedback` in a short framing ("An operator
has reviewed your progress and sent this guidance: …"), optionally folding in the last
verdict's failing checks if one exists (reuse `RepairPrompt`/`add_cross_agent_feedback`
shape). Clear `operator_feedback` + reset `repair_prompt_kind` on the green/settle path
exactly as the existing repair clauses do (`run.ex:647`).

### `data` fields to add

`hold_requested :: boolean()`, `operator_feedback :: String.t() | nil`,
`max_hold_timeout :: timeout()`. Extend the `repair_prompt_kind` union with
`:operator_steer`. Surface `held?`/hold reason in `Run.Status` so the dashboard and
`status/1` reflect it.

### Adapter capability degradation

Conversational resume is gated by `capabilities.session_resume` (`claude.ex:52`,
`agent_adapter.ex:433`). For `session_resume: false` adapters (antigravity), `steer`+`resume`
can't continue the conversation. Two honest options — pick one in implementation:
(a) reject `steer` with `{:error, :resume_unsupported}` for those adapters (operator falls
back to co-driving the worktree + a fresh re-dispatch), or (b) `resume` starts a *fresh*
attempt seeded with the operator note as the initial prompt (no continuity, but the
worktree's accumulated work is still there). Recommend (a) — explicit over silently lossy.

### Edge cases

- **Cancel during hold:** `cancel/1` from `:held` → `:failed` + teardown, as usual.
- **Hold racing a settle:** the graceful `hold_requested` flag is read at the single settle
  boundary, so there's no window where it both settles and holds.
- **Operator co-edits while a graceful hold's agent is still finishing:** that's why the
  *graceful* hold waits for the boundary before parking — the agent's Port and the
  operator's edits never write the worktree concurrently. (See Solution 2.)

---

## Solution 2 — operator co-drives the worktree (dashboard UI + the hold dependency)

The literal "same worktree" idea, and it falls out almost free once Solution 1 lands.

### Flow

1. Operator clicks **Hold** on a struggling run in the dashboard run table.
2. Run parks in `:held`; the dashboard run-detail surfaces the **worktree path**
   (already in `Run.Status.worktree_path`) with a copy affordance.
3. Operator opens a terminal in that worktree and does any of:
   - hand-edits files / fixes a blocker / drops a hint file the agent will see;
   - runs `claude --continue` themselves to interactively co-drive the *same* conversation,
     then exits.
4. Operator either types guidance into a **Steer** textarea (→ `Run.steer/2`) and/or just
   relies on the changed files, then clicks **Resume** (→ `Run.resume/1`). The agent's next
   attempt sees both the edited worktree and the steer note.

### Why the hold is load-bearing

Without `:held`, the agent's Port and the operator's edits race on the same files, and the
lifetime/watchdog timers would reap the run while the human is still in there. The hold
state is what makes stepping into the worktree *safe*. This is why Solution 2 depends on
Solution 1 and isn't a standalone.

### UI surface (this is the hand-buildable, operator-facing slice)

- Run table (`Harness.Dashboard` live): a **Hold** button on in-flight rows; held rows get a
  distinct badge (reuse the `bucket_badge/1` style) and a **Resume** / **Cancel** pair.
- Run-detail: worktree path with copy-to-clipboard, a **Steer** textarea + submit, a
  `claude --continue`-in-this-dir hint, and the current hold reason / `max_hold_timeout`
  countdown.
- All actions are LiveView events calling the `Run.hold/steer/resume` API; no new HTTP routes.

---

## Tests

- **Run gen_statem** (`test/harness/run_test.exs` or a focused recovery test): hold from
  `:running` (graceful + `interrupt:`) parks in `:held` and suspends the lifetime timer;
  `steer` stashes feedback; `resume` re-enters `:running` and `build_invocation/1` emits a
  `session: :resume` invocation carrying the operator prompt; `max_hold_timeout` settles
  `:failed` with `:hold_expired`; `cancel` from `:held` tears down; `steer` on a
  `session_resume: false` adapter returns `{:error, :resume_unsupported}` (option a). Drive
  with the existing test double adapter; assert via the `Invocation` the driver receives.
- **Dashboard** (`test/harness/dashboard/live_test.exs`): hold/resume/steer buttons render
  on the right rows, fire the right events, and the worktree path + held badge appear.

## Files

- `lib/harness/run.ex` — `:held` state fn, `hold/2`+`steer/2`+`resume/1` API,
  `build_invocation/1` operator-steer clause, `operator_steer_prompt/1`, data fields,
  `Run.Status` held fields.
- `lib/harness/run/status.ex` — held? + hold reason fields (if Status is separate).
- `lib/harness/dashboard/live.ex` + `components.ex` — hold/resume/steer controls, worktree
  path surface, held badge.
- `config/*.exs` — `:max_hold_timeout` default under `:run`.
- Tests above; `CHANGELOG.md`; `rmap` task on completion.

## Out of scope

- Live mid-token stdin steering (the EOF-spawn constraint; rejected above).
- Config *mutation* from the dashboard beyond the steer text.
- Multi-operator concurrent co-drive of one worktree (single operator assumed).
