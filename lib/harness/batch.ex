defmodule Harness.Batch do
  @moduledoc """
  Fans a set of roadmap items out across supervised `Harness.Run` lifecycles.

  `run/4` is deliberately synchronous: callers hand it already-ingested
  `Harness.Roadmap.Item`s, and it returns once every item has produced a
  terminal `Harness.Run.Result`. The concurrency cap controls how many run
  lifecycle children are in flight at the same time; red or failed runs are
  collected like any other result and never short-circuit the batch.
  """

  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Roadmap.Item
  alias Harness.Run.Result, as: RunResult
  alias Harness.Run.Supervisor, as: RunSupervisor

  @default_max_concurrency 1

  @typedoc "A reason `run/4` can fail before a batch starts."
  @type error :: {:invalid_max_concurrency, term()}

  @typep indexed_item :: {Item.t(), non_neg_integer()}
  @typep active_run :: %{
           index: non_neg_integer(),
           item: Item.t(),
           monitor_ref: reference(),
           result: RunResult.t() | nil
         }

  @doc """
  Runs `items` against `repo` with `adapter`, respecting `:max_concurrency`.

  Options are passed through to `Harness.Run.Supervisor.start_run/4`, except
  `:max_concurrency`, which defaults to `1`. The batch owns the per-run
  subscriber so it can collect each `{:harness_run, run_id, result}` message and
  return one `Harness.Batch.Result`.
  """
  @spec run([Item.t()], String.t(), module(), keyword()) :: {:ok, BatchResult.t()} | {:error, error()}
  def run(items, repo, adapter, opts \\ [])
      when is_list(items) and is_binary(repo) and is_atom(adapter) and is_list(opts) do
    with {:ok, max_concurrency} <- max_concurrency(opts) do
      run_opts = opts |> Keyword.delete(:max_concurrency) |> Keyword.put(:subscriber, self())
      indexed_items = Enum.with_index(items)

      results =
        indexed_items
        |> loop(%{}, %{}, repo, adapter, run_opts, max_concurrency, length(indexed_items))
        |> ordered_results(length(indexed_items))

      {:ok, %BatchResult{total: length(indexed_items), max_concurrency: max_concurrency, results: results}}
    end
  end

  @spec max_concurrency(keyword()) :: {:ok, pos_integer()} | {:error, error()}
  defp max_concurrency(opts) do
    cap = Keyword.get(opts, :max_concurrency) || configured(:max_concurrency, @default_max_concurrency)

    if is_integer(cap) and cap > 0 do
      {:ok, cap}
    else
      {:error, {:invalid_max_concurrency, cap}}
    end
  end

  @spec loop(
          [indexed_item()],
          %{String.t() => active_run()},
          %{non_neg_integer() => RunResult.t()},
          String.t(),
          module(),
          keyword(),
          pos_integer(),
          non_neg_integer()
        ) ::
          %{non_neg_integer() => RunResult.t()}
  defp loop(queue, active, results, repo, adapter, run_opts, max_concurrency, total) do
    {queue, active} = fill_slots(queue, active, repo, adapter, run_opts, max_concurrency)

    if map_size(results) == total do
      results
    else
      receive do
        {:harness_run, run_id, %RunResult{} = result} ->
          active = put_result(active, run_id, result)
          loop(queue, active, results, repo, adapter, run_opts, max_concurrency, total)

        {:DOWN, ref, :process, _pid, reason} ->
          {active, results} = settle_down(active, results, ref, reason)
          loop(queue, active, results, repo, adapter, run_opts, max_concurrency, total)
      end
    end
  end

  @spec fill_slots([indexed_item()], %{String.t() => active_run()}, String.t(), module(), keyword(), pos_integer()) ::
          {[indexed_item()], %{String.t() => active_run()}}
  defp fill_slots(queue, active, _repo, _adapter, _run_opts, max_concurrency) when map_size(active) >= max_concurrency do
    {queue, active}
  end

  defp fill_slots([], active, _repo, _adapter, _run_opts, _max_concurrency), do: {[], active}

  defp fill_slots([{%Item{} = item, index} | rest], active, repo, adapter, run_opts, max_concurrency) do
    {:ok, run_id, pid} = RunSupervisor.start_run(item, repo, adapter, run_opts)
    ref = Process.monitor(pid)
    active = Map.put(active, run_id, %{index: index, item: item, monitor_ref: ref, result: nil})
    fill_slots(rest, active, repo, adapter, run_opts, max_concurrency)
  end

  @spec put_result(%{String.t() => active_run()}, String.t(), RunResult.t()) :: %{String.t() => active_run()}
  defp put_result(active, run_id, result) do
    case Map.fetch(active, run_id) do
      {:ok, run} -> Map.put(active, run_id, %{run | result: result})
      :error -> active
    end
  end

  @spec settle_down(%{String.t() => active_run()}, %{non_neg_integer() => RunResult.t()}, reference(), term()) ::
          {%{String.t() => active_run()}, %{non_neg_integer() => RunResult.t()}}
  defp settle_down(active, results, ref, reason) do
    case find_by_monitor(active, ref) do
      nil ->
        {active, results}

      {run_id, run} ->
        result = run.result || crashed_result(run_id, run, reason)
        {Map.delete(active, run_id), Map.put(results, run.index, result)}
    end
  end

  @spec find_by_monitor(%{String.t() => active_run()}, reference()) :: {String.t(), active_run()} | nil
  defp find_by_monitor(active, ref) do
    Enum.find(active, fn {_run_id, run} -> run.monitor_ref == ref end)
  end

  @spec crashed_result(String.t(), active_run(), term()) :: RunResult.t()
  defp crashed_result(run_id, run, reason) do
    %RunResult{
      run_id: run_id,
      task_id: run.item.id,
      state: :failed,
      reason: {:run_crashed, reason}
    }
  end

  @spec ordered_results(%{non_neg_integer() => RunResult.t()}, non_neg_integer()) :: [RunResult.t()]
  defp ordered_results(_results, 0), do: []

  defp ordered_results(results, total) do
    Enum.map(0..(total - 1)//1, &Map.fetch!(results, &1))
  end

  @spec configured(atom(), term()) :: term()
  defp configured(key, default) do
    :harness |> Application.get_env(:batch, []) |> Keyword.get(key, default)
  end
end
