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
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Run.Result, as: RunResult
  alias Harness.Run.RetryPolicy
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Run.Worker, as: RunWorker

  require Logger

  @default_max_concurrency 1

  @typedoc "A reason `run/4` can fail before a batch starts."
  @type error ::
          {:invalid_max_concurrency, term()}
          | {:unknown_project, String.t()}
          | AgentRegistry.select_error()

  @typep indexed_item :: {Item.t(), non_neg_integer()}
  @typep active_worker :: %{
           index: non_neg_integer(),
           item: Item.t(),
           adapter: module() | nil,
           worker_pid: pid(),
           monitor_ref: reference(),
           started_at_ms: integer()
         }
  @typep loop_context :: %{
           batch_id: String.t(),
           project: Project.t(),
           adapters: [module()],
           run_opts: keyword(),
           retry_policy: RetryPolicy.t(),
           result_store: ResultStore.store(),
           max_concurrency: pos_integer(),
           total: non_neg_integer()
         }

  @typedoc "A reason `dispatch/2` can fail before jobs are enqueued."
  @type dispatch_error ::
          {:unknown_project, String.t()}
          | {:invalid_item_agent, term()}
          | {:project_register_failed, term()}
          | term()

  @doc """
  Enqueues one Oban-backed run job per item and returns immediately.

  The queue is project-scoped (`project_<name>`) and its local concurrency is
  controlled by the registered project's `concurrency_cap`.
  """
  @spec dispatch(Project.t() | String.t(), [Item.t()]) :: {:ok, [Oban.Job.t()]} | {:error, dispatch_error()}
  def dispatch(project, items) when is_list(items) do
    with {:ok, project} <- resolve_and_register_project(project) do
      enqueue_items(project, items)
    end
  end

  @spec dispatch([Item.t()], Project.t() | String.t()) :: {:ok, [Oban.Job.t()]} | {:error, dispatch_error()}
  def dispatch(items, project) when is_list(items), do: dispatch(project, items)

  @doc """
  Runs `items` against `project` (or a registered project name) with one
  adapter, or an ordered adapter list, respecting `:max_concurrency`.

  When `:max_concurrency` is omitted, the project's `concurrency_cap` is used
  when set; otherwise the global default applies.

  Options are passed through to `Harness.Run.Supervisor.start_run/4`, except
  `:max_concurrency`, which defaults to `1`. Each item's lifecycle is wrapped by
  `Harness.Run.RetryPolicy.run/2` (transient failures retry with capped backoff;
  quota-exhausted and terminal failures settle immediately). The retry policy
  is injectable via `:retry_policy` and defaults from `:harness, :retry_policy`.
  A concurrency slot is held for the full retry cycle, including backoff delays.

  When `adapter` is a list, the first available adapter whose capabilities
  satisfy `:required_capabilities` is selected for each dispatch. If a run's
  transcript indicates quota exhaustion, that adapter is marked unavailable and
  the same item is retried with the next capable adapter. If every capable
  adapter has been marked unavailable, queued items that have not yet been
  dispatched settle as `:failed` with reason `{:no_available_agent, _}` instead
  of crashing the batch. When `start_run/4` loses a concurrent availability race,
  selection is retried for the same item before the queue is settled.
  """
  @spec run([Item.t()], Project.t() | String.t(), module() | [module()], keyword()) ::
          {:ok, BatchResult.t()} | {:error, error()}
  def run(items, project, adapter, opts \\ []) when is_list(items) and is_list(opts) do
    adapters = List.wrap(adapter)

    with {:ok, project} <- resolve_project(project),
         {:ok, max_concurrency} <- max_concurrency(project, opts),
         :ok <- ensure_dispatchable(items, adapters, opts) do
      batch_id = Keyword.get(opts, :batch_id) || generate_batch_id()
      result_store = Keyword.get(opts, :result_store, ResultStore.configured())

      run_opts =
        opts
        |> Keyword.delete(:max_concurrency)
        |> Keyword.put(:batch_id, batch_id)
        |> Keyword.put(:result_store, result_store)

      retry_policy = RetryPolicy.from_opts(opts)
      indexed_items = Enum.with_index(items)

      context =
        loop_context(
          batch_id,
          project,
          adapters,
          run_opts,
          retry_policy,
          result_store,
          max_concurrency,
          length(indexed_items)
        )

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

  @spec resolve_and_register_project(Project.t() | String.t()) :: {:ok, Project.t()} | {:error, dispatch_error()}
  defp resolve_and_register_project(%Project{name: name} = project) do
    case ProjectRegistry.lookup(name) do
      {:ok, registered} ->
        {:ok, registered}

      {:error, {:unknown_project, ^name}} ->
        case ProjectRegistry.register(project) do
          :ok -> {:ok, project}
          {:error, reason} -> {:error, {:project_register_failed, reason}}
        end
    end
  end

  defp resolve_and_register_project(name) when is_binary(name), do: resolve_project(name)

  @spec enqueue_items(Project.t(), [Item.t()]) :: {:ok, [Oban.Job.t()]} | {:error, dispatch_error()}
  defp enqueue_items(%Project{} = project, items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, jobs} ->
      case enqueue_item(project, item) do
        {:ok, job} -> {:cont, {:ok, [job | jobs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  @spec enqueue_item(Project.t(), Item.t()) :: {:ok, Oban.Job.t()} | {:error, dispatch_error()}
  defp enqueue_item(%Project{} = project, %Item{} = item) do
    with {:ok, adapter} <- adapter_for_agent(item.agent) do
      args = %{
        project_name: project.name,
        item_id: item.id,
        adapter_module: Atom.to_string(adapter)
      }

      args
      |> RunWorker.new(queue: Harness.Oban.queue_name(project), meta: %{harness_stage: "dispatch"})
      |> Harness.Oban.insert()
    end
  end

  @spec adapter_for_agent(term()) :: {:ok, module()} | {:error, {:invalid_item_agent, term()}}
  defp adapter_for_agent(:claude), do: {:ok, Harness.AgentAdapter.Claude}
  defp adapter_for_agent(:codex), do: {:ok, Harness.AgentAdapter.Codex}
  defp adapter_for_agent(:cursor), do: {:ok, Harness.AgentAdapter.Cursor}
  defp adapter_for_agent(agent), do: {:error, {:invalid_item_agent, agent}}

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

  @spec resolve_project(Project.t() | String.t()) :: {:ok, Project.t()} | {:error, error()}
  defp resolve_project(%Project{} = project), do: {:ok, project}

  defp resolve_project(name) when is_binary(name) do
    case ProjectRegistry.lookup(name) do
      {:ok, project} -> {:ok, project}
      {:error, {:unknown_project, name}} -> {:error, {:unknown_project, name}}
    end
  end

  @spec max_concurrency(Project.t(), keyword()) :: {:ok, pos_integer()} | {:error, error()}
  defp max_concurrency(%Project{} = project, opts) do
    cap =
      Keyword.get(opts, :max_concurrency) ||
        project.concurrency_cap ||
        configured(:max_concurrency, @default_max_concurrency)

    if is_integer(cap) and cap > 0 do
      {:ok, cap}
    else
      {:error, {:invalid_max_concurrency, cap}}
    end
  end

  @spec loop(
          [indexed_item()],
          %{reference() => active_worker()},
          %{non_neg_integer() => RunResult.t()},
          [term()],
          loop_context()
        ) ::
          {%{non_neg_integer() => RunResult.t()}, [term()]}
  defp loop(queue, active, results, events, context) do
    {queue, active, results, events} =
      fill_slots(queue, active, results, events, context, context.max_concurrency)

    if map_size(results) == context.total do
      {results, events}
    else
      receive do
        {:batch_worker_done, worker_pid, outcome, _started_at_ms} ->
          {active, results, queue, events} =
            settle_worker_done(active, results, queue, events, context, worker_pid, outcome)

          loop(queue, active, results, events, context)

        {:DOWN, ref, :process, _pid, reason} ->
          {active, results, queue, events} =
            settle_worker_down(active, results, queue, events, context, ref, reason)

          loop(queue, active, results, events, context)
      end
    end
  end

  @spec loop_context(
          String.t(),
          Project.t(),
          [module()],
          keyword(),
          RetryPolicy.t(),
          ResultStore.store(),
          pos_integer(),
          non_neg_integer()
        ) :: loop_context()
  defp loop_context(batch_id, project, adapters, run_opts, retry_policy, result_store, max_concurrency, total) do
    %{
      batch_id: batch_id,
      project: project,
      adapters: adapters,
      run_opts: run_opts,
      retry_policy: retry_policy,
      result_store: result_store,
      max_concurrency: max_concurrency,
      total: total
    }
  end

  @spec fill_slots(
          [indexed_item()],
          %{reference() => active_worker()},
          %{non_neg_integer() => RunResult.t()},
          [term()],
          loop_context(),
          pos_integer()
        ) ::
          {[indexed_item()], %{reference() => active_worker()}, %{non_neg_integer() => RunResult.t()}, [term()]}
  defp fill_slots(queue, active, results, events, _context, max_concurrency) when map_size(active) >= max_concurrency do
    {queue, active, results, events}
  end

  defp fill_slots([], active, results, events, _context, _max_concurrency) do
    {[], active, results, events}
  end

  defp fill_slots([{%Item{} = item, index} = head | rest], active, results, events, context, max_concurrency) do
    case AgentRegistry.select(context.adapters,
           required_capabilities: Keyword.get(context.run_opts, :required_capabilities, [])
         ) do
      {:ok, _adapter} ->
        {active, events} = start_worker(active, index, item, events, context)
        fill_slots(rest, active, results, events, context, max_concurrency)

      {:error, {:no_available_agent, reason}} ->
        {results, events} = settle_undispatchable([head | rest], results, events, {:no_available_agent, reason})
        {[], active, results, events}

      {:error, reason} ->
        {results, events} = settle_undispatchable([head | rest], results, events, reason)
        {[], active, results, events}
    end
  end

  @spec start_worker(
          %{reference() => active_worker()},
          non_neg_integer(),
          Item.t(),
          [term()],
          loop_context()
        ) :: {%{reference() => active_worker()}, [term()]}
  defp start_worker(active, index, item, events, context) do
    parent = self()
    started_at_ms = System.monotonic_time(:millisecond)

    worker_pid =
      spawn(fn ->
        outcome =
          RetryPolicy.run(
            fn -> run_once(item, context.project, context.adapters, context.run_opts) end,
            context.retry_policy
          )

        send(parent, {:batch_worker_done, self(), outcome, started_at_ms})
      end)

    ref = Process.monitor(worker_pid)

    worker = %{
      index: index,
      item: item,
      adapter: nil,
      worker_pid: worker_pid,
      monitor_ref: ref,
      started_at_ms: started_at_ms
    }

    {Map.put(active, ref, worker), events}
  end

  # The worker's adapter-selection spin loop. `fill_slots/6` (the parent
  # process) gates on `AgentRegistry.select/2` before spawning a worker, but
  # the adapter list can flip unavailable between the parent's check and the
  # worker's own select — typically when another batch racing on the same
  # registry exhausts quota first. The worker retries up to this cap; if the
  # adapter is still unavailable on the last attempt the worker settles
  # `{:no_available_agent, :spin_exhausted}` so the result reason and event
  # log stay consistent with the parent's undispatchable settlement path
  # (`fill_slots/6` → `settle_undispatchable/4`) — never `:run_crashed`,
  # which would falsely imply a worker crash. See Task 57 (Round-4 audit).
  @spin_count_limit 100

  @spec run_once(Item.t(), Project.t(), [module()], keyword()) :: RunResult.t()
  defp run_once(%Item{} = item, project, adapters, run_opts) do
    run_once_dispatch(item, project, adapters, run_opts, 0)
  end

  @doc false
  # Public for unit testing the spin-exhausted settlement path without
  # engineering a parent/worker race against `AgentRegistry`. Production
  # callers always enter through `run_once/4`.
  @spec run_once_dispatch(Item.t(), Project.t(), [module()], keyword(), non_neg_integer()) :: RunResult.t()
  def run_once_dispatch(item, project, adapters, run_opts, spin_count) when spin_count < @spin_count_limit do
    run_opts = Keyword.put(run_opts, :subscriber, self())
    required = Keyword.get(run_opts, :required_capabilities, [])

    with {:ok, adapter} <- AgentRegistry.select(adapters, required_capabilities: required),
         {:ok, run_id, pid} <- RunSupervisor.start_run(item, project, adapter, run_opts) do
      ref = Process.monitor(pid)
      await_run(run_id, ref, item, adapter)
    else
      {:error, {:no_available_agent, _reason}} ->
        run_once_dispatch(item, project, adapters, run_opts, spin_count + 1)

      {:error, reason} ->
        %RunResult{
          run_id: undispatched_run_id(item),
          task_id: item.id,
          state: :failed,
          reason: {:run_crashed, {:start_run_failed, reason}}
        }
    end
  end

  def run_once_dispatch(item, _project, _adapters, _run_opts, _spin_count) do
    %RunResult{
      run_id: undispatched_run_id(item),
      task_id: item.id,
      state: :failed,
      reason: {:no_available_agent, :spin_exhausted}
    }
  end

  @spec await_run(String.t(), reference(), Item.t(), module()) :: RunResult.t()
  defp await_run(run_id, ref, item, _adapter) do
    receive do
      {:harness_run, ^run_id, %RunResult{} = result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        %RunResult{
          run_id: run_id,
          task_id: item.id,
          state: :failed,
          reason: {:run_crashed, reason}
        }
    end
  end

  @spec settle_worker_done(
          %{reference() => active_worker()},
          %{non_neg_integer() => RunResult.t()},
          [indexed_item()],
          [term()],
          loop_context(),
          pid(),
          term()
        ) ::
          {%{reference() => active_worker()}, %{non_neg_integer() => RunResult.t()}, [indexed_item()], [term()]}
  defp settle_worker_done(active, results, queue, events, context, worker_pid, outcome) do
    case find_by_worker_pid(active, worker_pid) do
      {ref, worker} ->
        Process.demonitor(ref, [:flush])
        active = Map.delete(active, ref)

        case outcome do
          {:ok, %RunResult{} = result, _attempts} ->
            {active, Map.put(results, worker.index, result), queue, events}

          {:failover, %RunResult{} = result, :quota_exhausted} ->
            fail_over(active, results, queue, events, context, worker, result)

          {:error, %RunResult{} = result, _reason} ->
            {active, Map.put(results, worker.index, result), queue, events}
        end

      :error ->
        {active, results, queue, events}
    end
  end

  @spec settle_worker_down(
          %{reference() => active_worker()},
          %{non_neg_integer() => RunResult.t()},
          [indexed_item()],
          [term()],
          loop_context(),
          reference(),
          term()
        ) ::
          {%{reference() => active_worker()}, %{non_neg_integer() => RunResult.t()}, [indexed_item()], [term()]}
  defp settle_worker_down(active, results, queue, events, context, ref, reason) do
    case Map.fetch(active, ref) do
      {:ok, worker} ->
        run_id = "worker-crashed-#{worker.item.id}-#{System.unique_integer([:positive, :monotonic])}"

        result =
          persist_crashed_result(
            crashed_result(run_id, worker, reason),
            worker,
            context
          )

        active = Map.delete(active, ref)
        {active, Map.put(results, worker.index, result), queue, events}

      :error ->
        {active, results, queue, events}
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

  @spec fail_over(
          %{reference() => active_worker()},
          %{non_neg_integer() => RunResult.t()},
          [indexed_item()],
          [term()],
          loop_context(),
          active_worker(),
          RunResult.t()
        ) ::
          {%{reference() => active_worker()}, %{non_neg_integer() => RunResult.t()}, [indexed_item()], [term()]}
  defp fail_over(active, results, queue, events, context, worker, result) do
    adapter = adapter_from_result(result)

    if adapter do
      :ok = AgentRegistry.mark_unavailable(adapter, {:quota_exhausted, worker.item.id})
      events = [{:adapter_unavailable, adapter, {:quota_exhausted, worker.item.id}} | events]
      maybe_requeue_after_failover(active, results, queue, events, context, worker, result, adapter)
    else
      {active, Map.put(results, worker.index, result), queue, events}
    end
  end

  @spec maybe_requeue_after_failover(
          %{reference() => active_worker()},
          %{non_neg_integer() => RunResult.t()},
          [indexed_item()],
          [term()],
          loop_context(),
          active_worker(),
          RunResult.t(),
          module()
        ) ::
          {%{reference() => active_worker()}, %{non_neg_integer() => RunResult.t()}, [indexed_item()], [term()]}
  defp maybe_requeue_after_failover(active, results, queue, events, context, worker, result, failed_adapter) do
    case AgentRegistry.select(context.adapters,
           required_capabilities: Keyword.get(context.run_opts, :required_capabilities, [])
         ) do
      {:ok, next_adapter} ->
        events = [{:failover, worker.item.id, failed_adapter, next_adapter} | events]
        {active, results, [{worker.item, worker.index} | queue], events}

      {:error, _reason} ->
        {active, Map.put(results, worker.index, result), queue, events}
    end
  end

  @spec adapter_from_result(RunResult.t()) :: module() | nil
  defp adapter_from_result(%RunResult{agent_outcome: %{run: %{adapter: adapter}}}) when is_atom(adapter), do: adapter

  defp adapter_from_result(_), do: nil

  @spec find_by_worker_pid(%{reference() => active_worker()}, pid()) ::
          {reference(), active_worker()} | :error
  defp find_by_worker_pid(active, worker_pid) do
    case Enum.find(active, fn {_ref, worker} -> worker.worker_pid == worker_pid end) do
      {ref, worker} -> {ref, worker}
      nil -> :error
    end
  end

  @spec crashed_result(String.t(), active_worker(), term()) :: RunResult.t()
  defp crashed_result(run_id, worker, reason) do
    %RunResult{
      run_id: run_id,
      task_id: worker.item.id,
      state: :failed,
      reason: {:run_crashed, reason}
    }
  end

  @spec persist_crashed_result(RunResult.t(), active_worker(), loop_context()) :: RunResult.t()
  defp persist_crashed_result(%RunResult{} = result, worker, context) do
    result
    |> LogRecord.from_result(
      batch_id: context.batch_id,
      agent: worker.item.agent,
      adapter: adapter_from_result(result) || List.first(context.adapters),
      duration_ms: run_duration_ms(worker)
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

  @spec run_duration_ms(active_worker()) :: non_neg_integer()
  defp run_duration_ms(worker) do
    max(0, System.monotonic_time(:millisecond) - worker.started_at_ms)
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
