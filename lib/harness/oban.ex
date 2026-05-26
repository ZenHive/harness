defmodule Harness.Oban do
  @moduledoc """
  Supervised Oban instance for persisted harness dispatch.

  Harness uses one Oban queue per registered project. Open-source Oban enforces
  each queue's local limit independently, so total local concurrency is the sum
  of all project queue limits.
  """

  use Supervisor

  alias Harness.Project
  alias Harness.ProjectRegistry

  @default_queue_limit 1

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
  Starts or scales the queue for `project` when Oban is running normally.
  """
  @spec ensure_project_queue(Project.t()) :: :ok | {:error, term()}
  def ensure_project_queue(%Project{} = project) do
    if queues_enabled?() and Process.whereis(__MODULE__) do
      Oban.start_queue(__MODULE__,
        queue: queue_name(project),
        limit: queue_limit(project),
        local_only: true
      )
    else
      :ok
    end
  end

  @doc """
  Returns the Oban queue name for a project.
  """
  @spec queue_name(Project.t() | String.t()) :: String.t()
  def queue_name(%Project{name: name}), do: queue_name(name)
  def queue_name(name) when is_binary(name), do: "project_#{name}"

  @doc false
  @spec bootstrap_project_queues() :: :ok
  def bootstrap_project_queues do
    Enum.each(ProjectRegistry.list(), &ensure_project_queue/1)
  end

  @spec oban_opts() :: keyword()
  defp oban_opts do
    base =
      :harness
      |> Application.get_env(Oban, [])
      |> Keyword.put_new(:name, __MODULE__)
      |> Keyword.put_new(:repo, Harness.Repo)
      |> Keyword.put_new(:queues, [])

    Keyword.put(base, :name, __MODULE__)
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
end
