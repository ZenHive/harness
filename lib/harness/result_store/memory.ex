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

  @table __MODULE__

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: :ok
  def record_run(%LogRecord{} = record, opts) when is_list(opts) do
    update(opts, fn state ->
      seq = state.seq + 1
      %{state | seq: seq, runs: Map.put(state.runs, record.run_id, {record, seq})}
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
  @spec mark_landed(String.t(), String.t(), keyword()) :: :ok
  def mark_landed(run_id, sha, opts) when is_binary(run_id) and is_binary(sha) and is_list(opts) do
    update(opts, fn state ->
      runs =
        case Map.fetch(state.runs, run_id) do
          {:ok, record_with_seq} -> Map.put(state.runs, run_id, mark_record_landed(record_with_seq, sha))
          :error -> state.runs
        end

      %{state | runs: runs}
    end)
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
  def reset(opts) when is_list(opts) do
    ensure_table()
    :ets.delete(@table, scope(opts))
    :ok
  end

  @spec update(keyword(), (map() -> map())) :: :ok
  defp update(opts, fun) do
    ensure_table()
    scope = scope(opts)
    :ets.insert(@table, {scope, fun.(read(opts))})
    :ok
  end

  @spec read(keyword()) :: map()
  defp read(opts) do
    ensure_table()

    case :ets.lookup(@table, scope(opts)) do
      [{_scope, state}] -> state
      [] -> empty()
    end
  end

  @spec ensure_table() :: :ok
  defp ensure_table do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec empty() :: map()
  defp empty do
    %{runs: %{}, batches: %{}, seq: 0}
  end

  @spec mark_record_landed({LogRecord.t(), non_neg_integer()}, String.t()) ::
          {LogRecord.t(), non_neg_integer()}
  defp mark_record_landed({%LogRecord{} = record, seq}, sha), do: {%{record | landed_sha: sha}, seq}

  @spec scope(keyword()) :: term()
  defp scope(opts), do: Keyword.get(opts, :scope, Keyword.get(opts, :root, :default))

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
