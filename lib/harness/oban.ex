defmodule Harness.Oban do
  @moduledoc """
  Supervised Oban instance for persisted harness dispatch.

  Harness uses one Oban queue per registered project. Open-source Oban enforces
  each queue's local limit independently, so total local concurrency is the sum
  of all project queue limits.
  """

  use Supervisor

  import Ecto.Query, only: [from: 2]

  alias Harness.Cron.RoadmapPoller
  alias Harness.Project
  alias Harness.ProjectRegistry

  @default_queue_limit 1
  @headroom_states ~w(available scheduled executing retryable)

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: Harness.Oban.Supervisor)
  end

  @impl Supervisor
  @spec init(term()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_init_arg) do
    children = [
      {Oban, oban_opts()},
      Harness.Oban.QueueBootstrap
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Inserts an Oban job through the harness instance.
  """
  @spec insert(Ecto.Changeset.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def insert(changeset) do
    case Application.get_env(:harness, :oban_insert) do
      fun when is_function(fun, 1) -> fun.(changeset)
      _other -> Oban.insert(__MODULE__, changeset)
    end
  end

  @doc """
  Starts or scales the queues for `project` when Oban is running normally.

  Each project gets two queues: the dispatch queue (`project_<name>`, sized to
  the concurrency cap) and the landing queue (`landing_<name>`, fixed at limit 1
  so the autonomous merge-train lands one approved run at a time per project).
  """
  @spec ensure_project_queue(Project.t()) :: :ok | {:error, term()}
  def ensure_project_queue(%Project{} = project) do
    if queues_enabled?() and Process.whereis(__MODULE__) do
      with :ok <-
             Oban.start_queue(__MODULE__,
               queue: queue_name(project),
               limit: queue_limit(project),
               local_only: true
             ) do
        Oban.start_queue(__MODULE__,
          queue: landing_queue_name(project),
          limit: 1,
          local_only: true
        )
      end
    else
      :ok
    end
  end

  @doc """
  Returns the Oban dispatch-queue name for a project.
  """
  @spec queue_name(Project.t() | String.t()) :: String.t()
  def queue_name(%Project{name: name}), do: queue_name(name)
  def queue_name(name) when is_binary(name), do: "project_#{name}"

  @doc """
  Returns the Oban landing-queue name for a project (`landing_<name>`).
  """
  @spec landing_queue_name(Project.t() | String.t()) :: String.t()
  def landing_queue_name(%Project{name: name}), do: landing_queue_name(name)
  def landing_queue_name(name) when is_binary(name), do: "landing_#{name}"

  @doc false
  @spec bootstrap_project_queues() :: :ok
  def bootstrap_project_queues do
    Enum.each(ProjectRegistry.list(), &ensure_project_queue/1)
  end

  @doc false
  @spec oban_opts() :: keyword()
  def oban_opts do
    base =
      :harness
      |> Application.get_env(Oban, [])
      |> Keyword.put_new(:name, __MODULE__)
      |> Keyword.put_new(:repo, Harness.Repo)
      |> Keyword.put_new(:queues, [])

    base
    |> maybe_enable_cron_queue()
    |> maybe_enable_cron_plugin()
    |> Keyword.put(:name, __MODULE__)
  end

  @doc false
  @spec queue_headroom?(Project.t()) :: boolean()
  def queue_headroom?(%Project{} = project) do
    if queues_enabled?() and Process.whereis(__MODULE__) do
      queued_job_count(project) < queue_limit(project)
    else
      true
    end
  end

  @spec queues_enabled?() :: boolean()
  defp queues_enabled? do
    :harness
    |> Application.get_env(Oban, [])
    |> Keyword.get(:testing, :disabled)
    |> Kernel.==(:disabled)
  end

  @spec queue_limit(Project.t()) :: pos_integer()
  defp queue_limit(%Project{concurrency_cap: cap}) when is_integer(cap) and cap > 0, do: cap
  defp queue_limit(%Project{}), do: @default_queue_limit

  @spec queued_job_count(Project.t()) :: non_neg_integer()
  defp queued_job_count(%Project{} = project) do
    queue = queue_name(project)

    query =
      from(job in Oban.Job,
        where: job.queue == ^queue and job.state in ^@headroom_states
      )

    Harness.Repo.aggregate(query, :count, :id)
  end

  @spec maybe_enable_cron_queue(keyword()) :: keyword()
  defp maybe_enable_cron_queue(opts) do
    if RoadmapPoller.enabled?() do
      {queue, limit} = RoadmapPoller.cron_queue_config()

      Keyword.update(opts, :queues, [{queue, limit}], fn
        queues when is_list(queues) -> Keyword.put_new(queues, queue, limit)
        _other -> [{queue, limit}]
      end)
    else
      opts
    end
  end

  @spec maybe_enable_cron_plugin(keyword()) :: keyword()
  defp maybe_enable_cron_plugin(opts) do
    if RoadmapPoller.enabled?() do
      Keyword.update(opts, :plugins, [RoadmapPoller.cron_plugin()], fn
        plugins when is_list(plugins) -> plugins ++ [RoadmapPoller.cron_plugin()]
        _other -> [RoadmapPoller.cron_plugin()]
      end)
    else
      opts
    end
  end
end
