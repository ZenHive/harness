defmodule Harness.ResultStore.Memory do
  @moduledoc """
  In-memory ephemeral `Harness.ResultStore` backend.

  Used when `:repo_enabled` is false: records remain observable inside the
  running BEAM but intentionally disappear on restart.
  """

  @behaviour Harness.ResultStore

  alias Harness.AgentKPI
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore
  alias Harness.Run.LogRecord
  alias Harness.Store.EtsScope
  alias Harness.TokenUsage

  @table __MODULE__

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: :ok
  def record_run(%LogRecord{} = record, opts) when is_list(opts) do
    update(opts, fn state ->
      seq = state.seq + 1
      runs = Map.update(state.runs, record.run_id, {record, seq}, &merge_record(&1, record, seq))

      %{state | seq: seq, runs: runs}
    end)
  end

  @impl Harness.ResultStore
  @spec save_batch(BatchResult.t(), keyword()) :: :ok
  def save_batch(%BatchResult{} = result, opts) when is_list(opts) do
    update(opts, fn state -> %{state | batches: Map.put(state.batches, result.batch_id, result)} end)
  end

  @impl Harness.ResultStore
  @spec load_batch(String.t(), keyword()) :: {:ok, BatchResult.t()} | {:error, :not_found}
  def load_batch(batch_id, opts) when is_binary(batch_id) and is_list(opts) do
    case Map.fetch(read(opts).batches, batch_id) do
      {:ok, %BatchResult{} = result} -> {:ok, result}
      :error -> {:error, :not_found}
    end
  end

  @impl Harness.ResultStore
  @spec list_run_records(Harness.ResultStore.filters(), keyword()) :: {:ok, [LogRecord.t()]}
  def list_run_records(filters, opts) when is_list(filters) and is_list(opts) do
    {limit, filters} = Harness.ResultStore.pop_limit(filters)
    {include_transcripts?, filters} = Keyword.pop(filters, :include_transcripts, false)
    point_lookup? = Keyword.has_key?(filters, :run_id)
    retain_outputs? = point_lookup? or include_transcripts?

    records =
      opts
      |> read()
      |> Map.fetch!(:runs)
      |> Map.values()
      |> Enum.sort_by(fn {_record, seq} -> seq end, :desc)
      |> Enum.map(fn {record, _seq} -> maybe_strip_agent_output(record, retain_outputs?) end)
      |> Enum.filter(&match_filters?(&1, filters))
      |> maybe_take(limit)

    {:ok, records}
  end

  @impl Harness.ResultStore
  @spec delete_run(String.t(), keyword()) :: :ok
  def delete_run(run_id, opts) when is_binary(run_id) and is_list(opts) do
    update(opts, fn state -> %{state | runs: Map.delete(state.runs, run_id)} end)
  end

  @impl Harness.ResultStore
  @spec mark_landed(String.t(), String.t(), keyword()) :: :ok | {:error, :run_record_not_found}
  def mark_landed(run_id, sha, opts) when is_binary(run_id) and is_binary(sha) and is_list(opts) do
    case Map.fetch(read(opts).runs, run_id) do
      {:ok, _record_with_seq} ->
        update(opts, fn state ->
          runs = Map.update!(state.runs, run_id, &mark_record_landed(&1, sha))
          %{state | runs: runs}
        end)

      :error ->
        # Mirror Postgres: missing row is not a silent success (Task 370).
        {:error, :run_record_not_found}
    end
  end

  @impl Harness.ResultStore
  @spec aggregate_by_agent(keyword(), keyword()) :: {:ok, AgentKPI.t()}
  def aggregate_by_agent(_query_opts, opts) when is_list(opts) do
    with {:ok, records} <- list_run_records([], opts) do
      {:ok, AgentKPI.aggregate(records)}
    end
  end

  @impl Harness.ResultStore
  @spec aggregate_reviewer_reliability(keyword(), keyword()) :: {:ok, AgentKPI.reviewer_ledger()}
  def aggregate_reviewer_reliability(_query_opts, opts) when is_list(opts) do
    with {:ok, records} <- list_run_records([], opts) do
      {:ok, AgentKPI.aggregate_reviewer_rejections(records)}
    end
  end

  @impl Harness.ResultStore
  @spec aggregate_by_facet(keyword(), keyword()) :: {:ok, [Harness.ResultStore.facet_group()]}
  def aggregate_by_facet(_query_opts, opts) when is_list(opts) do
    with {:ok, records} <- list_run_records([], opts) do
      groups =
        records
        |> CapabilityScore.build_scout_context()
        |> Enum.map(fn %{facet: facet, by_agent: agents} -> %{facet: facet, agents: agents} end)

      {:ok, groups}
    end
  end

  @doc false
  @spec reset(keyword()) :: :ok
  def reset(opts) when is_list(opts), do: EtsScope.reset(@table, opts)

  @spec update(keyword(), (map() -> map())) :: :ok
  defp update(opts, fun), do: EtsScope.update(@table, opts, empty(), fun)

  @spec read(keyword()) :: map()
  defp read(opts), do: EtsScope.read(@table, opts, empty())

  @spec empty() :: map()
  defp empty do
    %{runs: %{}, batches: %{}, seq: 0}
  end

  @spec mark_record_landed({LogRecord.t(), non_neg_integer()}, String.t()) ::
          {LogRecord.t(), non_neg_integer()}
  defp mark_record_landed({%LogRecord{} = record, seq}, sha), do: {%{record | landed_sha: sha}, seq}

  @spec merge_record({LogRecord.t(), non_neg_integer()}, LogRecord.t(), non_neg_integer()) ::
          {LogRecord.t(), non_neg_integer()}
  defp merge_record({%LogRecord{} = existing, _old_seq}, %LogRecord{} = incoming, seq) do
    {%{
       incoming
       | landed_sha: present(incoming.landed_sha, existing.landed_sha),
         verdict: present(incoming.verdict, existing.verdict),
         agent_outcome_kind: present(incoming.agent_outcome_kind, existing.agent_outcome_kind),
         agent_exit_status: present(incoming.agent_exit_status, existing.agent_exit_status),
         agent_diff_size: present(incoming.agent_diff_size, existing.agent_diff_size),
         reviewer_diff_size: present(incoming.reviewer_diff_size, existing.reviewer_diff_size),
         agent_output: non_empty_binary(incoming.agent_output, existing.agent_output),
         review_iterations: max_count(incoming.review_iterations, existing.review_iterations),
         reviewer_reprompt_count: max_count(incoming.reviewer_reprompt_count, existing.reviewer_reprompt_count),
         reviewer_rotation_count: max_count(incoming.reviewer_rotation_count, existing.reviewer_rotation_count),
         reviewer_adapter: present(incoming.reviewer_adapter, existing.reviewer_adapter),
         reviewer_model: present(incoming.reviewer_model, existing.reviewer_model),
         review_report: present(incoming.review_report, existing.review_report),
         reviewer_outcome_kind: present(incoming.reviewer_outcome_kind, existing.reviewer_outcome_kind),
         reviewer_exit_status: present(incoming.reviewer_exit_status, existing.reviewer_exit_status),
         reviewer_output: non_empty_binary(incoming.reviewer_output, existing.reviewer_output),
         review_facets: non_empty_map(incoming.review_facets, existing.review_facets),
         review_skills: non_empty_map(incoming.review_skills, existing.review_skills),
         review_checks: non_empty_map(incoming.review_checks, existing.review_checks),
         review_concerns: non_empty_list(incoming.review_concerns, existing.review_concerns),
         review_proposed_tasks: non_empty_list(incoming.review_proposed_tasks, existing.review_proposed_tasks),
         review_warning?: incoming.review_warning? or existing.review_warning?,
         review_ratings: non_empty_map(incoming.review_ratings, existing.review_ratings),
         recovery_attempts: max_count(incoming.recovery_attempts, existing.recovery_attempts),
         recovery_outcome: present(incoming.recovery_outcome, existing.recovery_outcome),
         recovery_repaired: present(incoming.recovery_repaired, existing.recovery_repaired),
         recovery_token_usage: measured_usage(incoming.recovery_token_usage, existing.recovery_token_usage),
         cold_check: non_empty_map(incoming.cold_check, existing.cold_check),
         approved_then_found_red: non_empty_map(incoming.approved_then_found_red, existing.approved_then_found_red)
     }, seq}
  end

  @spec present(term(), term()) :: term()
  defp present(nil, existing), do: existing
  defp present(incoming, _existing), do: incoming

  @spec non_empty_binary(binary(), binary()) :: binary()
  defp non_empty_binary("", existing), do: existing
  defp non_empty_binary(incoming, _existing), do: incoming

  @spec non_empty_map(map() | nil, map() | nil) :: map() | nil
  defp non_empty_map(nil, existing), do: existing
  defp non_empty_map(map, existing) when map == %{}, do: existing
  defp non_empty_map(incoming, _existing), do: incoming

  @spec non_empty_list([term()], [term()]) :: [term()]
  defp non_empty_list([], existing), do: existing
  defp non_empty_list(incoming, _existing), do: incoming

  @spec max_count(non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer()
  defp max_count(incoming, existing), do: max(incoming || 0, existing || 0)

  @spec measured_usage(TokenUsage.t(), TokenUsage.t()) :: TokenUsage.t()
  defp measured_usage(%TokenUsage{} = incoming, %TokenUsage{} = existing) do
    if TokenUsage.measured?(incoming), do: incoming, else: existing
  end

  @spec maybe_strip_agent_output(LogRecord.t(), boolean()) :: LogRecord.t()
  defp maybe_strip_agent_output(%LogRecord{} = record, true), do: record
  defp maybe_strip_agent_output(%LogRecord{} = record, false), do: %{record | agent_output: "", reviewer_output: ""}

  @spec maybe_take([LogRecord.t()], pos_integer() | nil) :: [LogRecord.t()]
  defp maybe_take(records, nil), do: records
  defp maybe_take(records, limit), do: Enum.take(records, limit)

  @spec match_filters?(LogRecord.t(), Harness.ResultStore.filters()) :: boolean()
  defp match_filters?(%LogRecord{} = record, filters) do
    Enum.all?(filters, fn {key, value} -> Map.get(record, key) == value end)
  end
end
