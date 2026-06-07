defmodule Harness.Cron.RoadmapPoller do
  @moduledoc """
  Cron-driven worker that polls registered project roadmaps for dispatchable work.

  Cron is a timer (mechanical); what it *triggers* is a two-path decision gated by
  a pure count — the mantra's "count facts in code; write the meaning with an AI"
  made literal:

    * **The gate (mechanical, every tick).** Count how many `rmap ready
      --dispatchable` tasks carry autonomous dispatch intent (a real, non-human
      `assignee`). Counting is ~free and decides nothing about grouping.
    * **One task → direct dispatch.** A lone task has no batching judgment to make,
      so it is routed by its `assignee` and enqueued without orchestrator overhead.
    * **Many tasks → the orchestrator AI** (`Harness.Cron.Orchestrator`). It reads
      the full ready set + in-flight touches + capability facts and emits a
      dispatch plan; harness reads the plan mechanically and enqueues it. The
      grouping/sequencing JUDGMENT (which tasks batch, which defer to avoid a
      stale-base collision, which inline) lives entirely in the plan artifact —
      never in a `cond`/regex here.

  Concurrency stays Oban's job — the `project_<name>` queue runs up to the
  project's `concurrency_cap` at once; the rest sit `available` and start as slots
  free. That queue limit is the mechanical ceiling the orchestrator's plan cannot
  override. Inserts are unique over `{project_name, item_id}` across non-terminal
  states, so a task already queued or running is not re-enqueued by a later tick —
  which is also how wave-pacing falls out of the cron cadence with no
  wave-tracking state in code.

  Agent routing resolves against `Harness.AgentRegistry` — the single source of
  truth for the agent set, so a new adapter is dispatchable with zero edits here.
  A `human` or *missing* assignee carries no autonomous dispatch intent and is
  logged + skipped — never defaulted to an agent (the retired `@default_agent`
  silently burned Opus on unrouted work). An assignee/adapter that names no
  harness adapter, or one the operator has disabled / that is quota-unavailable,
  is likewise logged and skipped via `AgentRegistry.select/2`.
  """

  use Oban.Worker, queue: :cron, max_attempts: 1

  alias Harness.AgentRegistry
  alias Harness.Cron.Orchestrator
  alias Harness.Cron.PendingDispatch
  alias Harness.Cron.Settings
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Run.Worker, as: RunWorker
  alias Oban.Plugins.Cron

  require Logger

  @cron_queue :cron
  @cron_queue_limit 1
  @dispatch_meta %{harness_stage: "cron_poll"}
  # The orchestrator reasons about touch-disjointness, so the ready set is
  # projected with full task context (not just routing keys) when fetched here.
  @orchestrator_ready_fields ~w(id assignee markers scores touches files_to_modify dep_layer title body)
  @default_subscription_env_scrubs %{
    claude: %{"ANTHROPIC_API_KEY" => false},
    codex: %{"OPENAI_API_KEY" => false}
  }
  # Dedup window: skip re-enqueueing a task that already has a job in any
  # non-terminal state. A completed/cancelled job does not block a later tick.
  @unique_opts [
    keys: [:project_name, :item_id],
    states: [:available, :scheduled, :executing, :retryable],
    period: :infinity
  ]

  @type cron_status ::
          :disabled
          | {:enabled, String.t(), DateTime.t() | :unknown}
          | {:invalid, String.t(), term()}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    if enabled?() do
      Enum.each(ProjectRegistry.list(), &poll_project/1)
    end

    :ok
  end

  @doc "Returns whether autonomous roadmap polling is enabled (the store-backed master switch)."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.master_enabled?()

  @doc "Returns the configured cron expression for roadmap polling (store-backed, default cadence otherwise)."
  @spec schedule() :: String.t()
  def schedule, do: Settings.schedule()

  @doc false
  @spec cron_entry() :: {String.t(), module(), keyword()}
  def cron_entry do
    {schedule(), __MODULE__, [queue: @cron_queue, max_attempts: 1]}
  end

  @doc false
  @spec cron_plugin() :: {module(), keyword()}
  def cron_plugin do
    {Cron, crontab: [cron_entry()]}
  end

  @doc false
  @spec cron_queue_config() :: {atom(), pos_integer()}
  def cron_queue_config, do: {@cron_queue, @cron_queue_limit}

  @doc "Returns the next scheduled poll tick from `now`."
  @spec next_tick(DateTime.t()) :: {:ok, DateTime.t() | :unknown} | {:error, term()}
  def next_tick(now \\ DateTime.utc_now()) do
    if enabled?(), do: compute_next_tick(now), else: {:error, :disabled}
  end

  @spec compute_next_tick(DateTime.t()) :: {:ok, DateTime.t() | :unknown} | {:error, term()}
  defp compute_next_tick(now) do
    case Cron.parse(schedule()) do
      {:ok, expression} -> handle_next_at(next_at(expression, now))
      {:error, _} = err -> err
    end
  end

  # `Oban.Cron.Expression` is internal to Oban and exposes an opaque
  # `Oban.Plugins.Cron.expression()`; `apply/2` evades the opacity check
  # without faking knowledge dialyzer can't reach through.
  @spec next_at(term(), DateTime.t()) :: DateTime.t() | :unknown | term()
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp next_at(expression, now), do: apply(Oban.Cron.Expression, :next_at, [expression, now])

  @spec handle_next_at(DateTime.t() | :unknown | term()) ::
          {:ok, DateTime.t() | :unknown} | {:error, term()}
  defp handle_next_at(%DateTime{} = tick), do: {:ok, tick}
  defp handle_next_at(:unknown), do: {:ok, :unknown}
  defp handle_next_at(other), do: {:error, {:unexpected_next_tick, other}}

  @doc "Returns the human-facing cron polling status."
  @spec status() :: cron_status()
  def status do
    case next_tick() do
      {:ok, tick} -> {:enabled, schedule(), tick}
      {:error, :disabled} -> :disabled
      {:error, reason} -> {:invalid, schedule(), reason}
    end
  end

  @spec poll_project(Project.t()) :: :ok
  defp poll_project(%Project{} = project) do
    if Settings.project_enabled?(project) do
      case ready_tasks(project) do
        {:ok, tasks} -> dispatch_decision(project, tasks)
        {:error, reason} -> log_ingest_error(project, reason)
      end
    else
      log_autonomy_skip(project)
    end
  end

  # The mechanical upside-count gate (mantra: count facts in code). Counting how
  # many tasks carry dispatch intent is pure arithmetic; the grouping JUDGMENT is
  # the orchestrator's, woken only when the count shows upside (≥2). Zero →
  # nothing; one → direct dispatch (no orchestrator overhead for a lone task);
  # many → the orchestrator decides the wave.
  @spec dispatch_decision(Project.t(), [map()]) :: :ok
  defp dispatch_decision(%Project{} = project, tasks) do
    {dispatchable, undispatchable} = Enum.split_with(tasks, &dispatchable?/1)
    Enum.each(undispatchable, &log_undispatchable(project, &1))

    case dispatchable do
      [] -> :ok
      [task] -> direct_dispatch(project, task)
      many -> orchestrate(project, many)
    end
  end

  # A task is autonomously dispatchable iff its assignee resolves to a real,
  # non-human agent. `human`/missing/unknown carry no routing intent and are
  # logged + skipped by `dispatch_decision` — never defaulted to an agent.
  @spec dispatchable?(map()) :: boolean()
  defp dispatchable?(task) do
    case task_agent(task) do
      agent when is_atom(agent) and agent not in [:human, :no_assignee] -> true
      _other -> false
    end
  end

  # The N==1 path: a lone task has no grouping to judge, so route by its assignee
  # and enqueue directly without paying the orchestrator round-trip.
  @spec direct_dispatch(Project.t(), map()) :: :ok
  defp direct_dispatch(%Project{} = project, task) do
    route_and_enqueue(project, to_string(task["id"]), task_agent(task))
  end

  # The N≥2 path: the orchestrator AI returns the dispatch plan; harness reads it
  # mechanically. An empty/malformed/agent-failed plan dispatches NOTHING this
  # tick (never a blind fan-out — that was the stale-base damage); the next tick
  # re-plans against the fresher base.
  @spec orchestrate(Project.t(), [map()]) :: :ok
  defp orchestrate(%Project{} = project, tasks) do
    case Orchestrator.plan(project, tasks) do
      {:ok, %Orchestrator{dispatch: dispatch, skip: skip}} ->
        ids = MapSet.new(tasks, &to_string(&1["id"]))
        Enum.each(dispatch, &enqueue_planned(project, &1, ids))
        Enum.each(skip, &log_plan_skip(project, &1))

      {:error, reason} ->
        log_orchestrator_error(project, reason)
    end
  end

  # The plan is the grouping JUDGMENT; harness validates only mechanically — the
  # task is in the woken set, the named adapter resolves, the agent is available —
  # then enqueues. Concurrency stays capped by the Oban queue limit.
  @spec enqueue_planned(Project.t(), Orchestrator.dispatch_entry(), MapSet.t()) :: :ok
  defp enqueue_planned(%Project{} = project, %{task_id: item_id, adapter: adapter}, ids) do
    with true <- MapSet.member?(ids, item_id),
         agent when is_atom(agent) <- resolve_assignee(adapter) do
      route_and_enqueue(project, item_id, agent)
    else
      false -> log_dispatch_skip(project, item_id, :not_in_ready_set)
      {:unsupported_assignee, raw} -> log_dispatch_skip(project, item_id, {:unsupported_adapter, raw})
    end
  end

  # Shared tail for both dispatch paths (the N==1 direct path and each N>=2
  # planned entry): resolve the agent to an adapter, apply the operator/
  # availability gate, then enqueue OR park. A disabled or quota-exhausted agent
  # is logged and skipped, never dispatched. The mode gate keys solely off the
  # project's dispatch mode — no "is this run high-stakes" judgment in code.
  @spec route_and_enqueue(Project.t(), String.t(), atom()) :: :ok
  defp route_and_enqueue(%Project{} = project, item_id, agent) when is_atom(agent) do
    with {:ok, adapter} <- AgentRegistry.delegatable_module_for_agent(agent),
         {:ok, adapter} <- AgentRegistry.select(adapter) do
      enqueue_or_park(project, item_id, adapter)
    else
      {:error, reason} -> log_dispatch_skip(project, item_id, reason)
    end
  end

  # The single enqueue boundary both autonomous paths share. Under `:manual` the
  # resolved decision is parked for operator approval; under `:auto` it is
  # enqueued exactly as before (byte-identical to the pre-Task-237 behaviour).
  @spec enqueue_or_park(Project.t(), String.t(), module()) :: :ok
  defp enqueue_or_park(%Project{} = project, item_id, adapter) do
    case Settings.dispatch_mode(project) do
      :manual -> park_for_approval(project, item_id, adapter)
      :auto -> auto_enqueue(project, item_id, adapter)
    end
  end

  @spec auto_enqueue(Project.t(), String.t(), module()) :: :ok
  defp auto_enqueue(%Project{} = project, item_id, adapter) do
    case enqueue_run(project, item_id, adapter) do
      {:ok, _job} -> :ok
      {:error, reason} -> log_dispatch_skip(project, item_id, reason)
    end
  end

  # Park the resolved decision instead of enqueueing. The env scrub is captured
  # now (same value the auto path applies) so approval honours it without
  # re-deriving. A witness event fires only on a freshly-parked decision, so a
  # re-tick of an already-parked task does not re-notify.
  @spec park_for_approval(Project.t(), String.t(), module()) :: :ok
  defp park_for_approval(%Project{} = project, item_id, adapter) do
    if Harness.Oban.unfinished_run_job?(project, item_id) do
      :ok
    else
      case PendingDispatch.park(project.name, item_id, adapter, env_scrub_for_adapter(adapter)) do
        {:parked, record} ->
          Notification.notify(park_event(project, record))
          log_park(project, item_id, adapter)

        {:exists, _record} ->
          :ok
      end
    end
  end

  @spec park_event(Project.t(), PendingDispatch.t()) :: Event.t()
  defp park_event(%Project{} = project, %PendingDispatch{} = record) do
    %Event{
      type: :dispatch_parked,
      task_id: record.task_id,
      project: project.name,
      outcome: %{adapter: inspect(record.adapter), pending_id: record.id}
    }
  end

  @doc """
  Resolves a task's `assignee` to a routing target.

  Returns `:human` or `:no_assignee` (both skipped — no autonomous dispatch
  intent), the resolved agent atom for a named one, or `{:unsupported_assignee,
  raw}` for a string that names no harness adapter. The assignee is resolved
  against `Harness.AgentRegistry.agents/0` — the registry is the single source of
  truth, so resolution is deterministic (no atom-table dependence) and a typo or
  unknown agent never reaches dispatch. A missing assignee is **never** defaulted
  to an agent (the retired `@default_agent` burned Opus on unrouted work).
  """
  @spec task_agent(map()) :: atom() | {:unsupported_assignee, String.t()}
  def task_agent(task) do
    case task["assignee"] do
      "human" -> :human
      assignee when is_binary(assignee) -> resolve_assignee(assignee)
      _missing -> :no_assignee
    end
  end

  @spec resolve_assignee(String.t()) :: AgentRegistry.agent() | {:unsupported_assignee, String.t()}
  defp resolve_assignee(assignee) do
    AgentRegistry.agents()
    |> Map.keys()
    |> Enum.find(&(Atom.to_string(&1) == assignee))
    |> case do
      nil -> {:unsupported_assignee, assignee}
      agent -> agent
    end
  end

  @spec enqueue_run(Project.t(), String.t(), module()) :: {:ok, Oban.Job.t()} | {:error, term()}
  defp enqueue_run(%Project{} = project, item_id, adapter) when is_binary(item_id) and is_atom(adapter) do
    args = %{
      project_name: project.name,
      item_id: item_id,
      adapter_module: Atom.to_string(adapter)
    }

    args
    |> put_env(env_scrub_for_adapter(adapter))
    |> RunWorker.new(queue: Harness.Oban.queue_name(project), meta: @dispatch_meta, unique: @unique_opts)
    |> Harness.Oban.insert()
  end

  @spec put_env(map(), map()) :: map()
  defp put_env(args, env) when is_map(env) and map_size(env) > 0, do: Map.put(args, :env, env)
  defp put_env(args, _empty), do: args

  @spec env_scrub_for_adapter(module()) :: %{optional(String.t()) => false}
  defp env_scrub_for_adapter(adapter) do
    with {:ok, agent} <- AgentRegistry.agent_for_module(adapter),
         env when is_map(env) and map_size(env) > 0 <- Map.get(subscription_env_scrubs(), agent, %{}) do
      env
    else
      _other -> %{}
    end
  end

  @spec subscription_env_scrubs() :: %{optional(atom()) => map() | false}
  defp subscription_env_scrubs do
    configured = Keyword.get(config(), :subscription_env_scrubs, %{})

    Map.merge(@default_subscription_env_scrubs, configured)
  end

  @spec ready_tasks(Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp ready_tasks(%Project{} = project) do
    case Application.get_env(:harness, :roadmap_ready) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.ready(project_root: project.roadmap_path, fields: @orchestrator_ready_fields)
    end
  end

  # A ready task with no autonomous dispatch intent (human / missing / unknown
  # assignee). Logged so an unrouted task is observable, never silently dropped.
  @spec log_undispatchable(Project.t(), map()) :: :ok
  defp log_undispatchable(%Project{} = project, task) do
    Logger.debug(
      "harness cron poller: #{project.name} task #{task["id"]} not dispatchable (assignee=#{inspect(task["assignee"])}), skipped"
    )
  end

  # The orchestrator's witness for a task it deliberately held back this wave.
  # Info-level so deferrals/inlines are visible in the operator log.
  @spec log_plan_skip(Project.t(), Orchestrator.skip_entry()) :: :ok
  defp log_plan_skip(%Project{} = project, %{task_id: id, disposition: disposition, reason: reason}) do
    Logger.info("harness cron poller: #{project.name} task #{id} #{disposition} by orchestrator: #{reason}")
  end

  @spec log_orchestrator_error(Project.t(), term()) :: :ok
  defp log_orchestrator_error(%Project{} = project, reason) do
    Logger.warning(
      "harness cron poller: #{project.name} orchestrator produced no plan (#{inspect(reason)}); dispatching nothing this tick"
    )
  end

  # Info-level (not debug) so a paused project is observable in the operator log,
  # not a silent skip — the 110 contract for per-project autonomy.
  @spec log_autonomy_skip(Project.t()) :: :ok
  defp log_autonomy_skip(%Project{} = project) do
    Logger.info("harness cron poller: #{project.name} autonomy disabled, skipped")
  end

  @spec log_ingest_error(Project.t(), term()) :: :ok
  defp log_ingest_error(%Project{} = project, reason) do
    Logger.debug("harness cron poller: #{project.name} roadmap ready skipped: #{inspect(reason)}")
  end

  @spec log_dispatch_skip(Project.t(), String.t(), term()) :: :ok
  defp log_dispatch_skip(%Project{} = project, item_id, reason) do
    Logger.debug("harness cron poller: #{project.name} task #{item_id} dispatch skipped: #{inspect(reason)}")
  end

  # Info-level so a parked decision is observable in the operator log — manual
  # mode holds the enqueue, and the operator needs to see what is awaiting them.
  @spec log_park(Project.t(), String.t(), module()) :: :ok
  defp log_park(%Project{} = project, item_id, adapter) do
    Logger.info(
      "harness cron poller: #{project.name} task #{item_id} parked for approval (mode=manual, adapter=#{inspect(adapter)})"
    )
  end

  @spec config() :: keyword()
  defp config do
    Application.get_env(:harness, :cron_polling, [])
  end
end
