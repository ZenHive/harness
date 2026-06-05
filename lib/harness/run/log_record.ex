defmodule Harness.Run.LogRecord do
  @moduledoc """
  Structured, queryable facts about one settled run attempt.

  Batch orchestration can fan a single task through multiple attempts when an
  adapter hits quota or becomes unavailable. Each attempt gets its own record so
  post-run analysis can reconstruct rejections, fail-overs, quota blocks, and
  agent comparison metrics without needing the original process to still exist.

  ## Reviewer verdict (`verdict`, `review_report`, `review_ratings`)

  The reviewer AI is the gate: `verdict` stores its decision (`:approve` /
  `:reject`, `nil` when the run never reached review), `review_report` its
  prose, and `review_ratings` its implementer KPI scores (performance,
  truthfulness, code quality, idiom usage, ...) — persisted verbatim as the
  scoring input for `Harness.AgentKPI` / capability routing.

  ## First-attempt pass (`reviewer_diff_size`, `review_iterations`)

  `reviewer_diff_size` is the changed-line count of the reviewer's own fixes on
  top of the implementer's delivery commit. `0` + `:approve` means the
  implementer's work needed no fixes — a first-attempt pass. `review_iterations`
  is derived from it (`0` when the reviewer changed nothing, `1` otherwise) so
  the column stays mechanically sourced.

  ## Reviewer output (`reviewer_output`, `reviewer_outcome_kind`, `reviewer_exit_status`)

  The reviewer agent's raw transcript (`reviewer_output`) and settled outcome
  facts (`reviewer_outcome_kind`, `reviewer_exit_status`), mirroring the
  implementer's `agent_output` / `agent_outcome_kind` / `agent_exit_status`.
  Persisted so a `:review_stuck` run (reviewer exited without writing the
  verdict file) is diagnosable after the fact — the dominant stuck mode is a
  *clean* reviewer exit, so the transcript shows what it did before omitting the
  write. Defaults (`""` / `nil`) when the run produced no clean reviewer outcome
  (killed by an idle/spawn timeout, crashed, or no reviewer available).

  ## Composed inputs (`composed_inputs`)

  Each dispatched attempt records the prompt/rule artifact assembled at the
  adapter boundary, tagged with its attempt number so post-hoc diagnosis can
  inspect the exact prompt that drove the agent.
  """

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentModel
  alias Harness.CapabilityDomain
  alias Harness.Run.Result, as: RunResult
  alias Harness.Run.Review
  alias Harness.TokenUsage

  @typedoc "One persisted run-attempt record."
  @type t :: %__MODULE__{
          batch_id: String.t(),
          run_id: String.t(),
          task_id: String.t(),
          project_name: String.t() | nil,
          agent: atom() | nil,
          model: String.t() | nil,
          adapter: module(),
          state: RunResult.state(),
          reason: RunResult.reason(),
          verdict: Review.verdict() | nil,
          duration_ms: non_neg_integer(),
          agent_diff_size: non_neg_integer() | nil,
          reviewer_diff_size: non_neg_integer() | nil,
          token_usage: TokenUsage.t(),
          composed_inputs: [AgentAdapter.composed_input()],
          agent_outcome_kind: Outcome.kind() | nil,
          agent_exit_status: integer() | nil,
          agent_output: binary(),
          reviewer_outcome_kind: Outcome.kind() | nil,
          reviewer_exit_status: integer() | nil,
          reviewer_output: binary(),
          domains: [CapabilityDomain.t()],
          reviewer_adapter: module() | nil,
          review_iterations: non_neg_integer(),
          review_report: String.t() | nil,
          review_ratings: %{optional(String.t()) => term()}
        }

  @enforce_keys [
    :batch_id,
    :run_id,
    :task_id,
    :adapter,
    :state,
    :reason,
    :duration_ms
  ]
  defstruct [
    :batch_id,
    :run_id,
    :task_id,
    :project_name,
    :agent,
    :model,
    :adapter,
    :state,
    :reason,
    :verdict,
    :duration_ms,
    :agent_diff_size,
    :reviewer_diff_size,
    :agent_outcome_kind,
    :agent_exit_status,
    token_usage: %TokenUsage{},
    composed_inputs: [],
    agent_output: "",
    reviewer_outcome_kind: nil,
    reviewer_exit_status: nil,
    reviewer_output: "",
    domains: [],
    reviewer_adapter: nil,
    review_iterations: 0,
    review_report: nil,
    review_ratings: %{}
  ]

  @doc "Builds a structured record from a settled run result and batch metadata."
  @spec from_result(RunResult.t(), keyword()) :: t()
  def from_result(%RunResult{} = result, meta) when is_list(meta) do
    record = %__MODULE__{
      batch_id: Keyword.fetch!(meta, :batch_id),
      run_id: result.run_id,
      task_id: result.task_id,
      project_name: Keyword.get(meta, :project_name),
      agent: Keyword.get(meta, :agent),
      model: record_model(result, meta),
      adapter: Keyword.fetch!(meta, :adapter),
      state: result.state,
      reason: result.reason,
      duration_ms: Keyword.fetch!(meta, :duration_ms),
      agent_diff_size: result.agent_diff_size,
      reviewer_diff_size: result.reviewer_diff_size,
      token_usage: result.token_usage,
      composed_inputs: result.composed_inputs,
      domains: domains_from_meta(meta),
      reviewer_adapter: result.reviewer_adapter,
      review_iterations: review_iterations(result.reviewer_diff_size)
    }

    record
    |> put_outcome(result.agent_outcome)
    |> put_reviewer_outcome(result.reviewer_outcome)
    |> put_review(result.review)
  end

  @doc """
  Returns the record's domain tags, defaulting pre-tagging persisted records to `[]`.
  """
  @spec domains(t()) :: [CapabilityDomain.t()]
  def domains(%__MODULE__{domains: domains}) when is_list(domains), do: domains
  def domains(_record), do: []

  @doc false
  @spec resolve_model(atom() | nil, binary(), String.t() | nil) :: String.t() | nil
  def resolve_model(agent, output, requested_model) do
    AgentModel.parse(agent, output) || requested_model
  end

  @spec record_model(RunResult.t(), keyword()) :: String.t() | nil
  defp record_model(result, meta) do
    resolve_model(
      Keyword.get(meta, :agent),
      agent_output(result.agent_outcome),
      Keyword.get(meta, :requested_model)
    )
  end

  @spec agent_output(Outcome.t() | nil) :: binary()
  defp agent_output(%Outcome{output: output}) when is_binary(output), do: output
  defp agent_output(_outcome), do: ""

  @spec put_outcome(t(), Outcome.t() | nil) :: t()
  defp put_outcome(record, nil), do: record

  defp put_outcome(record, %Outcome{} = outcome) do
    %{
      record
      | agent_outcome_kind: outcome.kind,
        agent_exit_status: outcome.exit_status,
        agent_output: outcome.output
    }
  end

  @spec put_reviewer_outcome(t(), Outcome.t() | nil) :: t()
  defp put_reviewer_outcome(record, nil), do: record

  defp put_reviewer_outcome(record, %Outcome{} = outcome) do
    %{
      record
      | reviewer_outcome_kind: outcome.kind,
        reviewer_exit_status: outcome.exit_status,
        reviewer_output: outcome.output
    }
  end

  @spec put_review(t(), Review.t() | nil) :: t()
  defp put_review(record, nil), do: record

  defp put_review(record, %Review{} = review) do
    %{record | verdict: review.verdict, review_report: review.report, review_ratings: review.ratings}
  end

  @spec domains_from_meta(keyword()) :: [CapabilityDomain.t()]
  defp domains_from_meta(meta) do
    meta
    |> Keyword.get(:domains, [])
    |> CapabilityDomain.normalize()
  end

  # "Did the reviewer have to fix anything?" as a 0/1 column, mechanically
  # derived from its own diff size.
  @spec review_iterations(non_neg_integer() | nil) :: 0 | 1
  defp review_iterations(diff_size) when is_integer(diff_size) and diff_size > 0, do: 1
  defp review_iterations(_diff_size), do: 0
end
