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
    point_lookup? = Keyword.has_key?(filters, :run_id)

    records =
      opts
      |> read()
      |> Map.fetch!(:runs)
      |> Map.values()
      |> Enum.sort_by(fn {_record, seq} -> seq end, :desc)
      |> Enum.map(fn {record, _seq} -> maybe_strip_agent_output(record, point_lookup?) end)
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
  @spec aggregate_by_agent(keyword(), keyword()) :: {:ok, AgentKPI.t()}
  def aggregate_by_agent(_query_opts, opts) when is_list(opts) do
    with {:ok, records} <- list_run_records([], opts) do
      {:ok, AgentKPI.aggregate(records)}
    end
  end

  @impl Harness.ResultStore
  @spec save_capability_score(CapabilityScore.t(), keyword()) :: :ok
  def save_capability_score(%CapabilityScore{} = score, opts) when is_list(opts) do
    key = {score.agent, score.domain, score.corpus_version}
    update(opts, fn state -> %{state | capability_scores: Map.put(state.capability_scores, key, score)} end)
  end

  @impl Harness.ResultStore
  @spec get_capability_score(atom(), atom(), String.t(), keyword()) ::
          {:ok, CapabilityScore.t()} | :no_data
  def get_capability_score(agent, domain, corpus_version, opts)
      when is_atom(agent) and is_atom(domain) and is_binary(corpus_version) and is_list(opts) do
    case Map.fetch(read(opts).capability_scores, {agent, domain, corpus_version}) do
      {:ok, %CapabilityScore{} = score} -> {:ok, score}
      :error -> :no_data
    end
  end

  @impl Harness.ResultStore
  @spec list_capability_scores(keyword()) :: {:ok, [CapabilityScore.t()]}
  def list_capability_scores(opts) when is_list(opts) do
    scores =
      opts
      |> read()
      |> Map.fetch!(:capability_scores)
      |> Map.values()
      |> Enum.sort_by(&{&1.domain, &1.agent, &1.corpus_version})

    {:ok, scores}
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
    %{runs: %{}, batches: %{}, capability_scores: %{}, seq: 0}
  end

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
