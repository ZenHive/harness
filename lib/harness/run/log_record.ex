defmodule Harness.Run.LogRecord do
  @moduledoc """
  Structured, queryable facts about one settled run attempt.

  Batch orchestration can fan a single task through multiple attempts when an
  adapter hits quota or becomes unavailable. Each attempt gets its own record so
  post-run analysis can reconstruct rejections, fail-overs, quota blocks, and
  agent comparison metrics without needing the original process to still exist.

  ## Reviewer verdict (`verdict`, `review_report`, `review_checks`, `review_concerns`,
  `review_proposed_tasks`, `review_facets`, `review_skills`, `review_ratings`)

  The reviewer AI is the gate: `verdict` stores its decision (`:approve` /
  `:reject`, `nil` when the run never reached review) and `review_report` its
  prose. `review_facets` is the routing KEY (open-vocabulary ground-truth
  characterization of what the task actually was) and `review_skills` the routing
  VALUE (two-axis domains × qualities rubric of `{score, note}` maps) — both
  persisted verbatim as raw facts an AI synthesizes capability from later (Task
  224). `review_ratings` is the legacy flat KPI block, kept for back-compat with
  pre-`skills` records. `review_checks` and `review_concerns` are the reviewer's
  structured check claim and self-flagged caveats; `review_warning?` is true when
  an approve carries non-empty concerns or a reviewer-authored `passed: false`
  check fact. `review_proposed_tasks` is the reviewer's raw discovery-proposal
  list, for the orchestrator to dedupe and file after landing. Harness never
  classifies prose or fuses these facts into a verdict.

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

  ## AI-recovery witness (`recovery_attempts`, `recovery_outcome`, `recovery_repaired`, `recovery_token_usage`)

  Raw facts about the bounded AI-recovery seam (`Harness.Run.Recovery`), persisted
  with no scoring: how many times recovery was spawned on this run, the last
  decision (`:repaired` / `:dead`), the AI's repair note, and the recovery token
  spend. The token figure is the witness metric that proves two-tier recovery is
  cheaper than a hard fail plus manual re-dispatch. All default to "recovery never
  ran" (`0` / `nil` / empty usage) for the overwhelming majority of runs.

  ## Landing witness (`landed_sha`)

  `landed_sha` is the lander's durable witness for this run: nil until the run is
  fast-forward-pushed, then the pushed commit SHA. Historical records created
  before this field existed remain nil and render as unmerged until re-landed.
  `task_fingerprint` is the dispatch-time stable task-content hash the lander
  uses to guard rmap writeback against numeric-id drift.

  ## Timing facts (`started_at`, `state_entered_at`)

  `started_at` is the run-start wall-clock timestamp. `state_entered_at` stores
  the latest wall-clock timestamp observed for each lifecycle state entered by
  the run. Historical rows created before these fields existed carry `nil` /
  `%{}`; consumers must treat them as optional facts.

  ## Post-merge cold-check witness (`cold_check`)

  `cold_check` is written by the post-merge audit AI in `.harness/audit.json`
  after it runs the project check in an intentionally un-warmed audit worktree.
  Harness persists the agent-written map as a fact; it never derives the result
  from a local shell exit code.

  ## False-approval witness (`approved_then_found_red`)

  `approved_then_found_red` is written only when that post-merge audit reports a
  red `cold_check` for a run the reviewer approved. It is an open map carrying
  the reviewer adapter/model plus the run's facet/domain facts and the raw
  `cold_check`. Missing/legacy rows read as `%{}`; harness counts its presence
  later, never parses audit prose or computes reviewer quality from it.
  """

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentModel
  alias Harness.CapabilityDomain
  alias Harness.Run.Recovery
  alias Harness.Run.Result, as: RunResult
  alias Harness.Run.Review
  alias Harness.TokenUsage

  @typedoc "One persisted run-attempt record."
  @type t :: %__MODULE__{
          batch_id: String.t(),
          run_id: String.t(),
          task_id: String.t(),
          task_fingerprint: String.t() | nil,
          project_name: String.t() | nil,
          agent: atom() | nil,
          model: String.t() | nil,
          started_at: DateTime.t() | nil,
          state_entered_at: %{optional(atom()) => DateTime.t()},
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
          reviewer_model: String.t() | nil,
          review_iterations: non_neg_integer(),
          reviewer_reprompt_count: non_neg_integer(),
          reviewer_rotation_count: non_neg_integer(),
          review_report: String.t() | nil,
          review_facets: %{optional(String.t()) => term()},
          review_skills: %{optional(String.t()) => term()},
          review_checks: %{optional(String.t()) => term()},
          review_concerns: [term()],
          review_proposed_tasks: [term()],
          review_warning?: boolean(),
          review_ratings: %{optional(String.t()) => term()},
          recovery_attempts: non_neg_integer(),
          recovery_outcome: Recovery.outcome() | nil,
          recovery_repaired: String.t() | nil,
          recovery_token_usage: TokenUsage.t(),
          landed_sha: String.t() | nil,
          cold_check: %{optional(String.t()) => term()} | nil,
          approved_then_found_red: %{optional(String.t()) => term()}
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
  # LogRecord is a deliberately flat persistence fact-record: run facts + reviewer
  # facts + recovery facts (Task 229), each a column the result store reads. Per
  # the mantra ("count facts in code"), these are facts, not behavior — the 34-field
  # count is the shape of the data, not a refactor smell.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :batch_id,
    :run_id,
    :task_id,
    :task_fingerprint,
    :project_name,
    :agent,
    :model,
    :started_at,
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
    state_entered_at: %{},
    composed_inputs: [],
    agent_output: "",
    reviewer_outcome_kind: nil,
    reviewer_exit_status: nil,
    reviewer_output: "",
    domains: [],
    reviewer_adapter: nil,
    reviewer_model: nil,
    review_iterations: 0,
    reviewer_reprompt_count: 0,
    reviewer_rotation_count: 0,
    review_report: nil,
    review_facets: %{},
    review_skills: %{},
    review_checks: %{},
    review_concerns: [],
    review_proposed_tasks: [],
    review_warning?: false,
    review_ratings: %{},
    recovery_attempts: 0,
    recovery_outcome: nil,
    recovery_repaired: nil,
    recovery_token_usage: %TokenUsage{},
    landed_sha: nil,
    cold_check: nil,
    approved_then_found_red: %{}
  ]

  @doc "Builds a structured record from a settled run result and batch metadata."
  @spec from_result(RunResult.t(), keyword()) :: t()
  def from_result(%RunResult{} = result, meta) when is_list(meta) do
    record = %__MODULE__{
      batch_id: Keyword.fetch!(meta, :batch_id),
      run_id: result.run_id,
      task_id: result.task_id,
      task_fingerprint: Keyword.get(meta, :task_fingerprint),
      project_name: Keyword.get(meta, :project_name),
      agent: Keyword.get(meta, :agent),
      model: record_model(result, meta),
      started_at: Keyword.get(meta, :started_at),
      state_entered_at: Keyword.get(meta, :state_entered_at, %{}),
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
      reviewer_model: result.reviewer_model || Keyword.get(meta, :reviewer_model),
      review_iterations: review_iterations(result.reviewer_diff_size),
      reviewer_reprompt_count: result.reviewer_reprompt_count,
      reviewer_rotation_count: result.reviewer_rotation_count,
      recovery_attempts: result.recovery_attempts,
      recovery_outcome: result.recovery_outcome,
      recovery_repaired: result.recovery_repaired,
      recovery_token_usage: result.recovery_token_usage
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
    %{
      record
      | verdict: review.verdict,
        review_report: review.report,
        review_facets: review.facets,
        review_skills: review.skills,
        review_checks: review.checks,
        review_concerns: review.concerns,
        review_proposed_tasks: review.proposed_tasks,
        review_warning?: Review.warning?(review),
        review_ratings: review.ratings
    }
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
