defmodule Harness.Run.LogRecord do
  @moduledoc """
  Structured, queryable facts about one settled run attempt.

  Batch orchestration can fan a single task through multiple attempts when an
  adapter hits quota or becomes unavailable. Each attempt gets its own record so
  post-run analysis can reconstruct red verdicts, fail-overs, quota blocks, and
  agent comparison metrics without needing the original process to still exist.
  """

  alias Harness.AgentAdapter.Outcome
  alias Harness.Run.Result, as: RunResult
  alias Harness.TokenUsage
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict

  @typedoc "A compact failed-check summary for logs and queries."
  @type failed_check :: %{
          name: String.t(),
          kind: :exited | :timed_out | :not_launched,
          exit_status: integer() | nil
        }

  @typedoc "Reconstructable failure cause carried by every run record."
  @type failure_cause :: %{
          reason: RunResult.reason(),
          failed_checks: [failed_check()]
        }

  @typedoc "One persisted run-attempt record."
  @type t :: %__MODULE__{
          batch_id: String.t(),
          run_id: String.t(),
          task_id: String.t(),
          agent: atom() | nil,
          adapter: module(),
          state: RunResult.state(),
          reason: RunResult.reason(),
          verdict: :pass | :fail | nil,
          duration_ms: non_neg_integer(),
          repair_attempts: non_neg_integer(),
          first_attempt_failed_check_count: non_neg_integer(),
          agent_diff_size: non_neg_integer() | nil,
          token_usage: TokenUsage.t(),
          failure_cause: failure_cause(),
          agent_outcome_kind: Outcome.kind() | nil,
          agent_exit_status: integer() | nil,
          agent_output: binary()
        }

  @enforce_keys [
    :batch_id,
    :run_id,
    :task_id,
    :adapter,
    :state,
    :reason,
    :duration_ms,
    :repair_attempts,
    :first_attempt_failed_check_count,
    :failure_cause
  ]
  defstruct [
    :batch_id,
    :run_id,
    :task_id,
    :agent,
    :adapter,
    :state,
    :reason,
    :verdict,
    :duration_ms,
    :repair_attempts,
    :first_attempt_failed_check_count,
    :agent_diff_size,
    :failure_cause,
    :agent_outcome_kind,
    :agent_exit_status,
    token_usage: %TokenUsage{},
    agent_output: ""
  ]

  @doc "Builds a structured record from a settled run result and batch metadata."
  @spec from_result(RunResult.t(), keyword()) :: t()
  def from_result(%RunResult{} = result, meta) when is_list(meta) do
    outcome = result.agent_outcome

    %__MODULE__{
      batch_id: Keyword.fetch!(meta, :batch_id),
      run_id: result.run_id,
      task_id: result.task_id,
      agent: Keyword.get(meta, :agent),
      adapter: Keyword.fetch!(meta, :adapter),
      state: result.state,
      reason: result.reason,
      verdict: verdict_status(result.verdict),
      duration_ms: Keyword.fetch!(meta, :duration_ms),
      repair_attempts: result.repair_attempts,
      first_attempt_failed_check_count: result.first_attempt_failed_check_count,
      agent_diff_size: result.agent_diff_size,
      token_usage: result.token_usage || %TokenUsage{},
      failure_cause: failure_cause(result),
      agent_outcome_kind: outcome && outcome.kind,
      agent_exit_status: outcome && outcome.exit_status,
      agent_output: (outcome && outcome.output) || ""
    }
  end

  @spec verdict_status(Verdict.t() | nil) :: :pass | :fail | nil
  defp verdict_status(%Verdict{status: status}), do: status
  defp verdict_status(nil), do: nil

  @spec failure_cause(RunResult.t()) :: failure_cause()
  defp failure_cause(%RunResult{} = result) do
    %{
      reason: result.reason,
      failed_checks: failed_checks(result.verdict)
    }
  end

  @spec failed_checks(Verdict.t() | nil) :: [failed_check()]
  defp failed_checks(%Verdict{results: results}) do
    results
    |> Enum.filter(&(&1.status == :fail))
    |> Enum.map(fn %CheckResult{} = result ->
      %{name: result.name, kind: result.kind, exit_status: result.exit_status}
    end)
  end

  defp failed_checks(nil), do: []
end
