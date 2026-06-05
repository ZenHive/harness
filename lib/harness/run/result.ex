defmodule Harness.Run.Result do
  @moduledoc """
  The final outcome of one `Harness.Run` lifecycle, delivered to the run's
  subscriber when it settles.

  A run settles into exactly one of two states — `:done` (the cross-family
  reviewer AI approved the work) or `:failed` (everything else: a rejection, a
  missing verdict artifact, a step that could not run, a crashed task, a
  cancellation, or the lifetime budget elapsed). `reason` carries the precise
  cause; `agent_outcome` and `review` are whatever evidence the run produced
  before it settled, each `nil` if the run never reached that step.

  The subscriber receives this struct as `{:harness_run, run_id, result}`.
  """

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Outcome
  alias Harness.Run.Review
  alias Harness.TokenUsage

  @typedoc "The terminal state a run settled into."
  @type state :: :done | :failed

  @typedoc """
  Why a run settled the way it did.

    * `:approved` — the reviewer AI approved the worktree (`:done`).
    * `{:review_rejected, report}` — the reviewer rejected the work; `report`
      is the reviewer's prose explaining why. Rejection is reserved for
      degenerate cases (nothing to salvage) — the task goes back to the queue.
    * `{:review_stuck, report}` — the gate could not produce a verdict: no
      cross-family reviewer was available, the reviewer failed to run or
      crashed, or it exited without writing a readable `.harness/review.json`.
    * `{:checkout_polluted, status}` — the agent leaked changes into the main
      checkout instead of its isolated worktree.
    * `{:checkout_pollution_check_failed, r}` — the pollution diff itself
      could not run.
    * `:cancelled` — the run was cancelled via `Harness.Run.cancel/1`.
    * `:timed_out` — the whole-job lifetime budget elapsed.
    * `{:memory_runaway, info}` — the per-run memory watchdog force-killed the
      spawned process tree (agent CLI + the `check_command` it forked) after its
      resident memory crossed the configured ceiling, so a runaway project check
      cannot OOM the host (Task 200). `info` carries `:role` (`:agent` |
      `:reviewer`), `:os_pid`, `:rss_kb`, and `:threshold_kb`.
    * `:hold_expired` — an operator-held run outlived the hold safeguard.
    * `{:reflex_halted, r}` — the deterministic mid-run reflex layer killed the
      agent for a mechanical liveness or blocked-command reason.
    * `{:worktree_failed, r}` — the isolated worktree could not be created.
    * `{:agent_spawn_failed, r}` — the agent never spawned (e.g. not on `PATH`).
    * `{:driver_crashed, r}` — the agent-driver task crashed.
    * `{:commit_failed, r}` — the agent's work could not be committed to the
      run branch. `{:worktree_missing, path}` means the run worktree directory
      disappeared before commit.
    * `{:run_crashed, r}` — the run process exited before delivering a result.
    * `{:no_available_agent, r}` — the batch could not pick an adapter for the
      item; the item never produced a run.
  """
  @type reason ::
          :approved
          | {:review_rejected, String.t()}
          | {:review_stuck, String.t()}
          | {:checkout_polluted, String.t()}
          | {:checkout_pollution_check_failed, term()}
          | :cancelled
          | :timed_out
          | {:memory_runaway, map()}
          | :hold_expired
          | {:reflex_halted, term()}
          | {:worktree_failed, term()}
          | {:agent_spawn_failed, term()}
          | {:driver_crashed, term()}
          | {:commit_failed, term()}
          | {:run_crashed, term()}
          | {:no_available_agent, term()}

  @typedoc """
  A settled run.

    * `run_id` — the run's unique id. For runs that reached the agent it is
      also the run's worktree id and `harness/<id>` branch suffix. Items that
      settled as `{:no_available_agent, _}` never produced a run and carry a
      synthetic `undispatched-<task-id>-<n>` id instead — no worktree, no
      branch.
    * `task_id` — the rmap task id the run served.
    * `state` — `:done` or `:failed`.
    * `reason` — the precise cause (see `t:reason/0`).
    * `agent_outcome` — the `Harness.AgentAdapter.Outcome`, or `nil` if the run
      failed before the agent ran.
    * `review` — the reviewer's parsed `.harness/review.json` verdict artifact
      (`Harness.Run.Review`), or `nil` if the run never produced one.
    * `worktree_path` — the isolated worktree's path, or `nil` if it was never
      created. On a `:failed` run the directory may have been retained for
      inspection.
    * `agent_diff_size` — changed-line count of the implementer's committed
      diff, or `nil` when no diff could be measured.
    * `reviewer_diff_size` — changed-line count of the reviewer's own fixes on
      top of the implementer's delivery commit, or `nil` when the run never
      reached review. `0` means the reviewer changed nothing — the
      implementer's work needed no fixes (first-attempt pass).
    * `token_usage` — `Harness.TokenUsage` parsed from the agent's raw
      transcript and summed across every dispatch, or an empty usage
      (all-`nil`) when the adapter's wire format reports no token counts.
    * `composed_inputs` — prompt/rule artifacts captured for each dispatch.
    * `reviewer_adapter` — the cross-family reviewer adapter that gated the
      run, or `nil` if the run never entered review.
    * `reviewer_outcome` — the reviewer agent's settled
      `Harness.AgentAdapter.Outcome` (its raw transcript in `.output`, plus
      `.kind` / `.exit_status`), or `nil` when the run never produced a clean
      reviewer outcome (killed by an idle/spawn timeout, crashed, or no
      cross-family reviewer was available). The dominant `:review_stuck` mode
      is a *clean* reviewer exit that simply omits the verdict file — there the
      outcome is present and is the highest-value diagnostic of why the gate
      produced nothing.
  """
  @type t :: %__MODULE__{
          run_id: String.t(),
          task_id: String.t(),
          state: state(),
          reason: reason(),
          agent_outcome: Outcome.t() | nil,
          review: Review.t() | nil,
          worktree_path: String.t() | nil,
          agent_diff_size: non_neg_integer() | nil,
          reviewer_diff_size: non_neg_integer() | nil,
          token_usage: TokenUsage.t(),
          composed_inputs: [AgentAdapter.composed_input()],
          reviewer_adapter: module() | nil,
          reviewer_outcome: Outcome.t() | nil
        }

  @enforce_keys [:run_id, :task_id, :state, :reason]
  defstruct [
    :run_id,
    :task_id,
    :state,
    :reason,
    :agent_outcome,
    :review,
    :worktree_path,
    agent_diff_size: nil,
    reviewer_diff_size: nil,
    token_usage: %TokenUsage{},
    composed_inputs: [],
    reviewer_adapter: nil,
    reviewer_outcome: nil
  ]
end
