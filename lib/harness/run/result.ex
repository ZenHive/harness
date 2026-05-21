defmodule Harness.Run.Result do
  @moduledoc """
  The final outcome of one `Harness.Run` lifecycle, delivered to the run's
  subscriber when it settles.

  A run settles into exactly one of two states — `:done` (the verification
  stack graded the worktree green) or `:failed` (everything else: a red
  verdict, a step that could not run, a crashed task, a cancellation, or the
  lifetime budget elapsed). `reason` carries the precise cause; `agent_outcome`
  and `verdict` are whatever evidence the run produced before it settled, each
  `nil` if the run never reached that step.

  The subscriber receives this struct as `{:harness_run, run_id, result}`.
  """

  alias Harness.AgentAdapter.Outcome
  alias Harness.Verification.Verdict

  @typedoc "The terminal state a run settled into."
  @type state :: :done | :failed

  @typedoc """
  Why a run settled the way it did.

    * `:passed` — the verification stack graded the worktree green (`:done`).
    * `:verification_red` — a check in the stack failed.
    * `:no_changes` — the agent terminated without changing the worktree, so
      there was nothing to commit; the run delivered nothing.
    * `:cancelled` — the run was cancelled via `Harness.Run.cancel/1`.
    * `:timed_out` — the whole-job lifetime budget elapsed.
    * `{:worktree_failed, r}` — the isolated worktree could not be created.
    * `{:agent_spawn_failed, r}` — the agent never spawned (e.g. not on `PATH`).
    * `{:driver_crashed, r}` — the agent-driver task crashed.
    * `{:commit_failed, r}` — the agent's work could not be committed to the
      run branch.
    * `{:verification_failed, r}` — verification could not run at all.
    * `{:verifier_crashed, r}` — the verification task crashed.
  """
  @type reason ::
          :passed
          | :verification_red
          | :no_changes
          | :cancelled
          | :timed_out
          | {:worktree_failed, term()}
          | {:agent_spawn_failed, term()}
          | {:driver_crashed, term()}
          | {:commit_failed, term()}
          | {:verification_failed, term()}
          | {:verifier_crashed, term()}

  @typedoc """
  A settled run.

    * `run_id` — the run's unique id (also its worktree id and branch suffix).
    * `task_id` — the rmap task id the run served.
    * `state` — `:done` or `:failed`.
    * `reason` — the precise cause (see `t:reason/0`).
    * `agent_outcome` — the `Harness.AgentAdapter.Outcome`, or `nil` if the run
      failed before the agent ran.
    * `verdict` — the `Harness.Verification.Verdict`, or `nil` if the run failed
      before verification.
    * `worktree_path` — the isolated worktree's path, or `nil` if it was never
      created. On a `:failed` run the directory may have been retained for
      inspection.
  """
  @type t :: %__MODULE__{
          run_id: String.t(),
          task_id: String.t(),
          state: state(),
          reason: reason(),
          agent_outcome: Outcome.t() | nil,
          verdict: Verdict.t() | nil,
          worktree_path: String.t() | nil
        }

  @enforce_keys [:run_id, :task_id, :state, :reason]
  defstruct [
    :run_id,
    :task_id,
    :state,
    :reason,
    :agent_outcome,
    :verdict,
    :worktree_path
  ]
end
