defmodule Harness.Cron.RoadmapPoller do
  @moduledoc """
  Cron-driven worker that polls registered project roadmaps for dispatchable work.

  Each tick dispatches the project's **parallel-safe batch** — every task in
  `rmap ready --dispatchable` (deps done, `handbuild` excluded), routed to its
  agent and enqueued as an independent `Harness.Run.Worker` job. Concurrency is
  Oban's job — the `project_<name>` queue runs up to the project's
  `concurrency_cap` at once; the rest sit `available` and start as slots free.
  Inserts are made unique over `{project_name, item_id}` across non-terminal
  states, so a task already queued or running is not re-enqueued by a later tick.

  Agent routing per task comes from rmap's `assignee` field. `human` assignees
  are skipped by autonomous dispatch; missing assignees, and assignees outside
  this autonomous worker's supported adapter set (for example `droid`), fall
  back to `:claude`. A task routed to an agent the operator has disabled (or
  that is quota-unavailable) is skipped via `AgentRegistry.select/2`.
  """

  use Oban.Worker, queue: :cron, max_attempts: 1

  alias Harness.AgentRegistry
  alias Harness.Cron.Settings
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Run.Worker, as: RunWorker
  alias Oban.Plugins.Cron

  require Logger

  @default_schedule "0 */2 * * *"
  @cron_queue :cron
  @cron_queue_limit 1
  @dispatch_meta %{harness_stage: "cron_poll"}
  @assignee_agents %{
    "claude" => :claude,
    "codex" => :codex,
    "cursor" => :cursor
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

  @doc "Returns whether autonomous roadmap polling is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    config()
    |> Keyword.get(:enabled, false)
    |> Kernel.==(true)
  end

  @doc "Returns the configured cron expression for roadmap polling."
  @spec schedule() :: String.t()
  def schedule do
    config()
    |> Keyword.get(:schedule, @default_schedule)
    |> to_string()
  end

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
        {:ok, tasks} -> Enum.each(tasks, &enqueue_task(project, &1))
        {:error, reason} -> log_ingest_error(project, reason)
      end
    else
      log_autonomy_skip(project)
    end
  end

  # One dispatchable task → one run job. Routing and the operator/availability
  # gate live in `select/2`; a task routed to a disabled or quota-exhausted agent
  # is logged and skipped, never dispatched.
  @spec enqueue_task(Project.t(), map()) :: :ok
  defp enqueue_task(%Project{} = project, task) when is_map(task) do
    item_id = to_string(task["id"])

    case task_agent(task) do
      :human ->
        log_dispatch_skip(project, item_id, :human_assigned)

      agent ->
        with {:ok, adapter} <- AgentRegistry.delegatable_module_for_agent(agent),
             {:ok, adapter} <- AgentRegistry.select(adapter),
             {:ok, _job} <- enqueue_run(project, item_id, adapter) do
          :ok
        else
          {:error, reason} -> log_dispatch_skip(project, item_id, reason)
        end
    end
  end

  @doc false
  @spec task_agent(map()) :: atom()
  def task_agent(task) do
    case task["assignee"] do
      "human" -> :human
      assignee when is_binary(assignee) -> Map.get(@assignee_agents, assignee, :claude)
      _other -> :claude
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
    |> RunWorker.new(queue: Harness.Oban.queue_name(project), meta: @dispatch_meta, unique: @unique_opts)
    |> Harness.Oban.insert()
  end

  @spec ready_tasks(Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp ready_tasks(%Project{} = project) do
    case Application.get_env(:harness, :roadmap_ready) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.ready(project_root: project.roadmap_path)
    end
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

  @spec config() :: keyword()
  defp config do
    Application.get_env(:harness, :cron_polling, [])
  end
end
