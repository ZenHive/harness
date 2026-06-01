defmodule Harness.Run.LogRecord do
  @moduledoc """
  Structured, queryable facts about one settled run attempt.

  Batch orchestration can fan a single task through multiple attempts when an
  adapter hits quota or becomes unavailable. Each attempt gets its own record so
  post-run analysis can reconstruct red verdicts, fail-overs, quota blocks, and
  agent comparison metrics without needing the original process to still exist.

  ## Per-check output (`check_output`)

  A record also carries the captured stdout+stderr of each *failed* check, so a
  later JSON/MCP caller can read *why* a check failed without the original
  `%Run.Result{}` still being in memory. It is deliberately bounded: only failing
  checks are kept (a green run carries an empty map) and each is tail-truncated to
  `@check_output_cap_bytes` (16 KB) — a single verdict can emit megabytes, and the
  diagnostic signal (the failing assertion, the credo/dialyzer warning, the test
  summary) lands at the tail.

  ## Composed inputs (`composed_inputs`)

  Each dispatched attempt records the prompt/rule artifact assembled at the
  adapter boundary. Repair attempts are separate entries tagged with their
  attempt number so post-hoc diagnosis can inspect the exact feedback prompt
  that resumed the agent.
  """

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentModel
  alias Harness.CapabilityDomain
  alias Harness.Run.Result, as: RunResult
  alias Harness.TokenUsage
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict

  @check_output_cap_bytes 16_000

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

  @typedoc """
  Captured output of each failed check, keyed by check name.

  Only failing checks are present (a green verdict yields `%{}`); each entry's
  `output` is the combined stdout+stderr tail-truncated to `@check_output_cap_bytes`,
  with `truncated: true` when it was capped.
  """
  @type check_output :: %{optional(String.t()) => %{output: String.t(), truncated: boolean()}}

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
          verdict: :pass | :fail | nil,
          duration_ms: non_neg_integer(),
          repair_attempts: non_neg_integer(),
          first_attempt_failed_check_count: non_neg_integer(),
          agent_diff_size: non_neg_integer() | nil,
          token_usage: TokenUsage.t(),
          composed_inputs: [AgentAdapter.composed_input()],
          failure_cause: failure_cause(),
          agent_outcome_kind: Outcome.kind() | nil,
          agent_exit_status: integer() | nil,
          agent_output: binary(),
          check_output: check_output(),
          domains: [CapabilityDomain.t()]
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
    :project_name,
    :agent,
    :model,
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
    composed_inputs: [],
    agent_output: "",
    check_output: %{},
    domains: []
  ]

  @doc "Builds a structured record from a settled run result and batch metadata."
  @spec from_result(RunResult.t(), keyword()) :: t()
  def from_result(%RunResult{} = result, meta) when is_list(meta) do
    outcome = result.agent_outcome

    %__MODULE__{
      batch_id: Keyword.fetch!(meta, :batch_id),
      run_id: result.run_id,
      task_id: result.task_id,
      project_name: Keyword.get(meta, :project_name),
      agent: Keyword.get(meta, :agent),
      model: AgentModel.parse(Keyword.get(meta, :agent), (outcome && outcome.output) || ""),
      adapter: Keyword.fetch!(meta, :adapter),
      state: result.state,
      reason: result.reason,
      verdict: verdict_status(result.verdict),
      duration_ms: Keyword.fetch!(meta, :duration_ms),
      repair_attempts: result.repair_attempts,
      first_attempt_failed_check_count: result.first_attempt_failed_check_count,
      agent_diff_size: result.agent_diff_size,
      token_usage: result.token_usage || %TokenUsage{},
      composed_inputs: result.composed_inputs || [],
      failure_cause: failure_cause(result),
      agent_outcome_kind: outcome && outcome.kind,
      agent_exit_status: outcome && outcome.exit_status,
      agent_output: (outcome && outcome.output) || "",
      check_output: check_output(result.verdict),
      domains: domains_from_meta(meta)
    }
  end

  @doc """
  Returns the record's domain tags, defaulting pre-tagging persisted records to `[]`.
  """
  @spec domains(t()) :: [CapabilityDomain.t()]
  def domains(%__MODULE__{domains: domains}) when is_list(domains), do: domains
  def domains(_record), do: []

  @spec domains_from_meta(keyword()) :: [CapabilityDomain.t()]
  defp domains_from_meta(meta) do
    meta
    |> Keyword.get(:domains, [])
    |> CapabilityDomain.normalize()
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

  # Capture only the failing checks' output (the "why did it fail" signal); a
  # green verdict carries none. Each output is tail-truncated — failures surface
  # at the end of test/credo/dialyzer output.
  @spec check_output(Verdict.t() | nil) :: check_output()
  defp check_output(%Verdict{results: results}) do
    results
    |> Enum.filter(&(&1.status == :fail))
    |> Map.new(fn %CheckResult{} = result ->
      {capped, truncated?} = cap_output(result.output)
      {result.name, %{output: capped, truncated: truncated?}}
    end)
  end

  defp check_output(nil), do: %{}

  # Keep the last @check_output_cap_bytes bytes (the diagnostic tail), flagging
  # whether the output was capped.
  @spec cap_output(String.t()) :: {String.t(), boolean()}
  defp cap_output(output) when byte_size(output) <= @check_output_cap_bytes, do: {output, false}

  defp cap_output(output) do
    tail = binary_part(output, byte_size(output) - @check_output_cap_bytes, @check_output_cap_bytes)
    {valid_utf8_tail(tail), true}
  end

  # Tail truncation can split a multi-byte codepoint at the FRONT of the kept
  # slice; drop leading bytes until the remainder is valid UTF-8.
  @spec valid_utf8_tail(binary()) :: binary()
  defp valid_utf8_tail(<<>>), do: <<>>

  defp valid_utf8_tail(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_tail(binary_part(bin, 1, byte_size(bin) - 1))
  end
end
