defmodule Harness.Batch do
  @moduledoc """
  Fans a set of roadmap items out across supervised `Harness.Run` lifecycles.

  `run/4` is deliberately synchronous: callers hand it already-ingested
  `Harness.Roadmap.Item`s, and it returns once every item has produced a
  terminal `Harness.Run.Result`. The concurrency cap controls how many run
  lifecycle children are in flight at the same time; red or failed runs are
  collected like any other result and never short-circuit the batch.
  """

  alias Harness.AgentRegistry
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Run.Result, as: RunResult
  alias Harness.Run.Supervisor, as: RunSupervisor

  require Logger

  @default_max_concurrency 1

  @typedoc "A reason `run/4` can fail before a batch starts."
  @type error :: {:invalid_max_concurrency, term()} | AgentRegistry.select_error()

  @typep indexed_item :: {Item.t(), non_neg_integer()}
  @typep active_run :: %{
           index: non_neg_integer(),
           item: Item.t(),
           adapter: module(),
           monitor_ref: reference(),
           started_at_ms: integer(),
           result: RunResult.t() | nil
         }
  @typep loop_context :: %{
           batch_id: String.t(),
           repo: String.t(),
           adapters: [module()],
           run_opts: keyword(),
           result_store: ResultStore.store(),
           max_concurrency: pos_integer(),
           total: non_neg_integer()
         }

  @doc """
  Runs `items` against `repo` with one adapter, or an ordered adapter list,
  respecting `:max_concurrency`.

  Options are passed through to `Harness.Run.Supervisor.start_run/4`, except
  `:max_concurrency`, which defaults to `1`. The batch owns the per-run
  subscriber so it can collect each `{:harness_run, run_id, result}` message and
  return one `Harness.Batch.Result`.

  When `adapter` is a list, the first available adapter whose capabilities
  satisfy `:required_capabilities` is selected for each dispatch. If a run's
  transcript indicates quota exhaustion, that adapter is marked unavailable and
  the same item is retried with the next capable adapter. If every capable
  adapter has been marked unavailable, queued items that have not yet been
  dispatched settle as `:failed` with reason `{:no_available_agent, _}` instead
  of crashing the batch.
  """
  @spec run([Item.t()], String.t(), module() | [module()], keyword()) ::
          {:ok, BatchResult.t()} | {:error, error()}
  def run(items, repo, adapter, opts \\ []) when is_list(items) and is_binary(repo) and is_list(opts) do
    adapters = List.wrap(adapter)

    with {:ok, max_concurrency} <- max_concurrency(opts),
         :ok <- ensure_dispatchable(items, adapters, opts) do
      batch_id = Keyword.get(opts, :batch_id) || generate_batch_id()
      result_store = Keyword.get(opts, :result_store, ResultStore.configured())

      run_opts =
        opts
        |> Keyword.delete(:max_concurrency)
        |> Keyword.put(:batch_id, batch_id)
        |> Keyword.put(:result_store, result_store)
        |> Keyword.put(:subscriber, self())

      indexed_items = Enum.with_index(items)
      context = loop_context(batch_id, repo, adapters, run_opts, result_store, max_concurrency, length(indexed_items))

      {results, events} = loop(indexed_items, %{}, %{}, [], context)

      result = %BatchResult{
        batch_id: batch_id,
        total: length(indexed_items),
        max_concurrency: max_concurrency,
        results: ordered_results(results, length(indexed_items)),
        events: Enum.reverse(events)
      }

      persist_batch(result, result_store)
      {:ok, result}
    end
  end

  @spec ensure_dispatchable([Item.t()], [module()], keyword()) ::
          :ok | {:error, AgentRegistry.select_error()}
  defp ensure_dispatchable([], _adapters, _opts), do: :ok

  defp ensure_dispatchable([%Item{} | _items], adapters, opts) do
    required_capabilities = Keyword.get(opts, :required_capabilities, [])

    case AgentRegistry.select(adapters, required_capabilities: required_capabilities) do
      {:ok, _adapter} -> :ok
      {:error, _reason} = error -> error
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
          [term()],
          loop_context()
        ) ::
          {%{non_neg_integer() => RunResult.t()}, [term()]}
  defp loop(queue, active, results, events, context) do
    {queue, active, results, events} =
      fill_slots(
        queue,
        active,
        results,
        events,
        context.repo,
        context.adapters,
        context.run_opts,
        context.max_concurrency
      )

    if map_size(results) == context.total do
      {results, events}
    else
      receive do
        {:harness_run, run_id, %RunResult{} = result} ->
          active = put_result(active, run_id, result)
          loop(queue, active, results, events, context)

        {:DOWN, ref, :process, _pid, reason} ->
          {active, results, queue, events} =
            settle_down(active, results, queue, events, context, ref, reason)

          loop(queue, active, results, events, context)
      end
    end
  end

  @spec loop_context(String.t(), String.t(), [module()], keyword(), ResultStore.store(), pos_integer(), non_neg_integer()) ::
          loop_context()
  defp loop_context(batch_id, repo, adapters, run_opts, result_store, max_concurrency, total) do
    %{
      batch_id: batch_id,
      repo: repo,
      adapters: adapters,
      run_opts: run_opts,
      result_store: result_store,
      max_concurrency: max_concurrency,
      total: total
    }
  end

  @spec fill_slots(
          [indexed_item()],
          %{String.t() => active_run()},
          %{non_neg_integer() => RunResult.t()},
          [term()],
          String.t(),
          [module()],
          keyword(),
          pos_integer()
        ) ::
          {[indexed_item()], %{String.t() => active_run()}, %{non_neg_integer() => RunResult.t()}, [term()]}
  defp fill_slots(queue, active, results, events, _repo, _adapters, _run_opts, max_concurrency)
       when map_size(active) >= max_concurrency do
    {queue, active, results, events}
  end

  defp fill_slots([], active, results, events, _repo, _adapters, _run_opts, _max_concurrency) do
    {[], active, results, events}
  end

  defp fill_slots(
         [{%Item{} = item, index} = head | rest],
         active,
         results,
         events,
         repo,
         adapters,
         run_opts,
         max_concurrency
       ) do
    case AgentRegistry.select(adapters, required_capabilities: Keyword.get(run_opts, :required_capabilities, [])) do
      {:ok, adapter} ->
        # TODO(Task 35): start_run/4 can also return {:error, _} (e.g. DynamicSupervisor
        # capacity, agent driver init crash) — this unconditional pattern match crashes
        # the batch in that case, the sibling of the {:no_available_agent, _} path below.
        {:ok, run_id, pid} = RunSupervisor.start_run(item, repo, adapter, run_opts)
        ref = Process.monitor(pid)

        active =
          Map.put(active, run_id, %{
            index: index,
            item: item,
            adapter: adapter,
            monitor_ref: ref,
            started_at_ms: System.monotonic_time(:millisecond),
            result: nil
          })

        fill_slots(rest, active, results, events, repo, adapters, run_opts, max_concurrency)

      {:error, reason} ->
        {results, events} = settle_undispatchable([head | rest], results, events, reason)
        {[], active, results, events}
    end
  end

  @spec settle_undispatchable(
          [indexed_item()],
          %{non_neg_integer() => RunResult.t()},
          [term()],
          AgentRegistry.select_error()
        ) ::
          {%{non_neg_integer() => RunResult.t()}, [term()]}
  defp settle_undispatchable(queue, results, events, reason) do
    Enum.reduce(queue, {results, events}, fn {%Item{} = item, index}, {results, events} ->
      result = %RunResult{
        run_id: undispatched_run_id(item),
        task_id: item.id,
        state: :failed,
        reason: {:no_available_agent, reason}
      }

      events = [{:no_available_agent, item.id, reason} | events]
      {Map.put(results, index, result), events}
    end)
  end

  @spec undispatched_run_id(Item.t()) :: String.t()
  defp undispatched_run_id(%Item{id: id}) do
    "undispatched-#{id}-#{System.unique_integer([:positive, :monotonic])}"
  end

  @spec put_result(%{String.t() => active_run()}, String.t(), RunResult.t()) :: %{String.t() => active_run()}
  defp put_result(active, run_id, result) do
    case Map.fetch(active, run_id) do
      {:ok, run} -> Map.put(active, run_id, %{run | result: result})
      :error -> active
    end
  end

  @spec settle_down(
          %{String.t() => active_run()},
          %{non_neg_integer() => RunResult.t()},
          [indexed_item()],
          [term()],
          loop_context(),
          reference(),
          term()
        ) ::
          {%{String.t() => active_run()}, %{non_neg_integer() => RunResult.t()}, [indexed_item()], [term()]}
  defp settle_down(active, results, queue, events, context, ref, reason) do
    case find_by_monitor(active, ref) do
      nil ->
        {active, results, queue, events}

      {run_id, run} ->
        result = run.result || persist_crashed_result(crashed_result(run_id, run, reason), run, context)
        active = Map.delete(active, run_id)

        if quota_exhausted_result?(result) do
          fail_over(active, results, queue, events, context.adapters, context.run_opts, run, result)
        else
          {active, Map.put(results, run.index, result), queue, events}
        end
    end
  end

  @spec fail_over(
          %{String.t() => active_run()},
          %{non_neg_integer() => RunResult.t()},
          [indexed_item()],
          [term()],
          [module()],
          keyword(),
          active_run(),
          RunResult.t()
        ) ::
          {%{String.t() => active_run()}, %{non_neg_integer() => RunResult.t()}, [indexed_item()], [term()]}
  defp fail_over(active, results, queue, events, adapters, run_opts, run, result) do
    :ok = AgentRegistry.mark_unavailable(run.adapter, {:quota_exhausted, run.item.id})
    events = [{:adapter_unavailable, run.adapter, {:quota_exhausted, run.item.id}} | events]

    case AgentRegistry.select(adapters, required_capabilities: Keyword.get(run_opts, :required_capabilities, [])) do
      {:ok, next_adapter} ->
        events = [{:failover, run.item.id, run.adapter, next_adapter} | events]
        {active, results, [{run.item, run.index} | queue], events}

      {:error, _reason} ->
        {active, Map.put(results, run.index, result), queue, events}
    end
  end

  @spec quota_exhausted_result?(RunResult.t()) :: boolean()
  defp quota_exhausted_result?(%RunResult{state: :failed, agent_outcome: outcome}) do
    AgentRegistry.quota_exhausted?(outcome)
  end

  defp quota_exhausted_result?(%RunResult{}), do: false

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

  @spec persist_crashed_result(RunResult.t(), active_run(), loop_context()) :: RunResult.t()
  defp persist_crashed_result(%RunResult{} = result, run, context) do
    result
    |> LogRecord.from_result(
      batch_id: context.batch_id,
      agent: run.item.agent,
      adapter: run.adapter,
      duration_ms: run_duration_ms(run)
    )
    |> ResultStore.record_run(context.result_store)
    |> log_store_error("run record", result.run_id)

    result
  end

  @spec persist_batch(BatchResult.t(), ResultStore.store()) :: :ok
  defp persist_batch(%BatchResult{} = result, result_store) do
    result
    |> ResultStore.save_batch(result_store)
    |> log_store_error("batch result", result.batch_id)
  end

  @spec log_store_error(:ok | {:error, term()}, String.t(), String.t()) :: :ok
  defp log_store_error(:ok, _kind, _id), do: :ok

  defp log_store_error({:error, reason}, kind, id) do
    Logger.warning("harness batch: failed to persist #{kind} #{id}: #{inspect(reason)}")
    :ok
  end

  @spec run_duration_ms(active_run()) :: non_neg_integer()
  defp run_duration_ms(run) do
    max(0, System.monotonic_time(:millisecond) - run.started_at_ms)
  end

  @spec generate_batch_id() :: String.t()
  defp generate_batch_id do
    rand = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "batch-#{System.system_time(:millisecond)}-#{rand}"
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
