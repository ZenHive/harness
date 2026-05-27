defmodule Harness.Cron.RoadmapPoller do
  @moduledoc """
  Cron-driven worker that polls registered project roadmaps for dispatchable work.
  """

  use Oban.Worker, queue: :cron, max_attempts: 1

  alias Harness.AgentRegistry
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run.Worker, as: RunWorker
  alias Oban.Plugins.Cron

  require Logger

  @default_schedule "0 */2 * * *"
  @cron_queue :cron
  @cron_queue_limit 1
  @dispatch_meta %{harness_stage: "cron_poll"}

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
  @spec cron_plugin() :: {module(), keyword()}
  def cron_plugin do
    {Cron, crontab: [{schedule(), __MODULE__, [queue: @cron_queue, max_attempts: 1]}]}
  end

  @doc false
  @spec cron_queue_config() :: {atom(), pos_integer()}
  def cron_queue_config, do: {@cron_queue, @cron_queue_limit}

  @doc "Returns the next scheduled poll tick from `now`."
  @spec next_tick(DateTime.t()) :: {:ok, DateTime.t() | :unknown} | {:error, term()}
  def next_tick(now \\ DateTime.utc_now()) do
    if enabled?() do
      with {:ok, expression} <- Cron.parse(schedule()) do
        case apply(Oban.Cron.Expression, :next_at, [expression, now]) do
          %DateTime{} = tick -> {:ok, tick}
          :unknown -> {:ok, :unknown}
          other -> {:error, {:unexpected_next_tick, other}}
        end
      end
    else
      {:error, :disabled}
    end
  end

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
    case ingest_next(project) do
      {:ok, %Item{} = item} -> maybe_enqueue(project, item)
      {:error, :no_pending_task} -> :ok
      {:error, reason} -> log_ingest_error(project, reason)
    end
  end

  @spec maybe_enqueue(Project.t(), Item.t()) :: :ok
  defp maybe_enqueue(%Project{} = project, %Item{} = item) do
    with true <- queue_headroom?(project),
         {:ok, adapter} <- adapter_for_agent(item.agent),
         {:ok, adapter} <- AgentRegistry.select(adapter),
         {:ok, _job} <- enqueue_run(project, item, adapter) do
      :ok
    else
      false -> :ok
      {:error, reason} -> log_dispatch_skip(project, item, reason)
    end
  end

  @spec enqueue_run(Project.t(), Item.t(), module()) :: {:ok, Oban.Job.t()} | {:error, term()}
  defp enqueue_run(%Project{} = project, %Item{} = item, adapter) when is_atom(adapter) do
    args = %{
      project_name: project.name,
      item_id: item.id,
      adapter_module: Atom.to_string(adapter)
    }

    args
    |> RunWorker.new(queue: Harness.Oban.queue_name(project), meta: @dispatch_meta)
    |> Harness.Oban.insert()
  end

  @spec ingest_next(Project.t()) :: {:ok, Item.t()} | {:error, term()}
  defp ingest_next(%Project{} = project) do
    case Application.get_env(:harness, :roadmap_ingest) do
      fun when is_function(fun, 2) -> fun.(:next, project_root: project.roadmap_path)
      _other -> Roadmap.ingest(:next, project_root: project.roadmap_path)
    end
  end

  @spec queue_headroom?(Project.t()) :: boolean()
  defp queue_headroom?(%Project{} = project) do
    case Application.get_env(:harness, :queue_headroom?) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Harness.Oban.queue_headroom?(project)
    end
  end

  @spec adapter_for_agent(term()) :: {:ok, module()} | {:error, {:invalid_item_agent, term()}}
  defp adapter_for_agent(:claude), do: {:ok, Harness.AgentAdapter.Claude}
  defp adapter_for_agent(:codex), do: {:ok, Harness.AgentAdapter.Codex}
  defp adapter_for_agent(:cursor), do: {:ok, Harness.AgentAdapter.Cursor}
  defp adapter_for_agent(agent), do: {:error, {:invalid_item_agent, agent}}

  @spec log_ingest_error(Project.t(), term()) :: :ok
  defp log_ingest_error(%Project{} = project, reason) do
    Logger.debug("harness cron poller: #{project.name} roadmap ingest skipped: #{inspect(reason)}")
  end

  @spec log_dispatch_skip(Project.t(), Item.t(), term()) :: :ok
  defp log_dispatch_skip(%Project{} = project, %Item{} = item, reason) do
    Logger.debug("harness cron poller: #{project.name} task #{item.id} dispatch skipped: #{inspect(reason)}")
  end

  @spec config() :: keyword()
  defp config do
    Application.get_env(:harness, :cron_polling, [])
  end
end
