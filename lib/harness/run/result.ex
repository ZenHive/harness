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

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Outcome
  alias Harness.TokenUsage
  alias Harness.Verification.Verdict

  @typedoc "The terminal state a run settled into."
  @type state :: :done | :failed

  @typedoc """
  Why a run settled the way it did.

    * `:passed` — the verification stack graded the worktree green (`:done`).
    * `:verification_red` — a check in the stack failed; any configured repair
      attempts were exhausted without going green (see `repair_attempts`).
    * `:semantic_rejection` — the verification stack was green, but the
      configured cross-family semantic gate rejected the committed diff against
      the task body and acceptance criteria.
    * `:no_changes` — the agent terminated without changing the worktree, so
      there was nothing to commit; the run delivered nothing.
    * `{:checkout_polluted, status}` — reserved. Since Task 66 the run
      lifecycle no longer snapshots or diffs the main checkout for adapters
      declaring `worktree_isolation: true` (every shipped adapter today;
      adapters declaring `false` fail earlier with
      `{:agent_spawn_failed, {:worktree_isolation_unsupported, _, _}}`), so
      `Harness.Run` does not currently surface this reason. Preserved in the
      type for callers using `Harness.Worktree.Isolation.check_pollution/3`
      directly and for a future correlation-based detector.
    * `{:checkout_pollution_check_failed, r}` — reserved. Same lineage as
      `:checkout_polluted`: would surface only from a runtime pollution check,
      which `Harness.Run` no longer performs.
    * `:cancelled` — the run was cancelled via `Harness.Run.cancel/1`.
    * `:timed_out` — the whole-job lifetime budget elapsed.
    * `{:reflex_halted, r}` — the deterministic mid-run reflex layer killed the
      agent for a mechanical liveness or blocked-command reason, then routed
      the task through `Harness.Lander.Resilience`.
    * `{:worktree_failed, r}` — the isolated worktree could not be created.
    * `{:agent_spawn_failed, r}` — the agent never spawned (e.g. not on `PATH`).
    * `{:driver_crashed, r}` — the agent-driver task crashed.
    * `{:commit_failed, r}` — the agent's work could not be committed to the
      run branch. `{:worktree_missing, path}` means the run worktree directory
      disappeared before commit.
    * `{:verification_failed, r}` — verification could not run at all.
    * `{:verifier_crashed, r}` — the verification task crashed.
    * `{:run_crashed, r}` — the run process exited before delivering a result.
    * `{:no_available_agent, r}` — the batch could not pick an adapter for the
      item; the item never produced a run. Used when every capable adapter has
      been marked unavailable (typically by quota fail-over) before the item
      reached `start_run`.
  """
  @type reason ::
          :passed
          | :verification_red
          | :semantic_rejection
          | :no_changes
          | {:checkout_polluted, String.t()}
          | {:checkout_pollution_check_failed, term()}
          | :cancelled
          | :timed_out
          | :hold_expired
          | {:reflex_halted, term()}
          | {:worktree_failed, term()}
          | {:agent_spawn_failed, term()}
          | {:driver_crashed, term()}
          | {:commit_failed, term()}
          | {:verification_failed, term()}
          | {:verifier_crashed, term()}
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
    * `verdict` — the `Harness.Verification.Verdict`, or `nil` if the run failed
      before verification.
    * `worktree_path` — the isolated worktree's path, or `nil` if it was never
      created. On a `:failed` run the directory may have been retained for
      inspection.
    * `repair_attempts` — how many repair attempts the run made before settling.
      `0` when the first verification settled the run; up to the configured
      `:max_repair_attempts` when a red verdict drove the autonomous repair loop
      (see `Harness.Run`). `agent_outcome` and `verdict` then reflect the final
      attempt.
    * `first_attempt_failed_check_count` — number of failed checks in the first
      verification verdict, before any repair attempt.
    * `agent_diff_size` — changed-line count for the agent's first committed
      diff, or `nil` when no diff could be measured.
    * `token_usage` — `Harness.TokenUsage` parsed from the agent's raw
      transcript and summed across every repair attempt, or an empty usage
      (all-`nil`) when the adapter's wire format reports no token counts.
    * `composed_inputs` — prompt/rule artifacts captured for each dispatch
      attempt, including repair attempts.
  """
  @type t :: %__MODULE__{
          run_id: String.t(),
          task_id: String.t(),
          state: state(),
          reason: reason(),
          agent_outcome: Outcome.t() | nil,
          verdict: Verdict.t() | nil,
          worktree_path: String.t() | nil,
          repair_attempts: non_neg_integer(),
          first_attempt_failed_check_count: non_neg_integer(),
          agent_diff_size: non_neg_integer() | nil,
          token_usage: TokenUsage.t(),
          composed_inputs: [AgentAdapter.composed_input()]
        }

  @enforce_keys [:run_id, :task_id, :state, :reason]
  defstruct [
    :run_id,
    :task_id,
    :state,
    :reason,
    :agent_outcome,
    :verdict,
    :worktree_path,
    repair_attempts: 0,
    first_attempt_failed_check_count: 0,
    agent_diff_size: nil,
    token_usage: %TokenUsage{},
    composed_inputs: []
  ]
end
