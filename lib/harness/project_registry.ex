defmodule Harness.ProjectRegistry do
  @moduledoc """
  In-memory registry of `%Harness.Project{}` records.

  Projects boot from `config :harness, :projects` and can be registered at
  runtime via `register/1`.
  """

  use GenServer

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset
  alias Harness.Project

  require Logger

  @type error :: {:duplicate, String.t()} | {:unknown_project, String.t()} | {:invalid_project, term()}

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl GenServer
  @spec init(term()) :: {:ok, %{projects: %{String.t() => Project.t()}}}
  def init(_init_arg) do
    projects =
      :harness
      |> Application.get_env(:projects, [])
      |> Enum.reduce(%{}, fn entry, acc ->
        case build_project(entry) do
          {:ok, project} ->
            Map.put(acc, project.name, project)

          {:error, reason} ->
            Logger.warning("harness project registry: skipping invalid config entry: #{inspect(reason)}")
            acc
        end
      end)

    {:ok, %{projects: projects}}
  end

  @doc """
  Registers `project` under its `name`. Returns `{:error, {:duplicate, name}}`
  when the name is already taken.
  """
  @spec register(Project.t()) :: :ok | {:error, error()}
  def register(%Project{} = project) do
    GenServer.call(__MODULE__, {:register, project})
  end

  @doc """
  Looks up a project by slug `name`.
  """
  @spec lookup(String.t()) :: {:ok, Project.t()} | {:error, error()}
  def lookup(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:lookup, name})
  end

  @doc """
  Lists every registered project, sorted by name.
  """
  @spec list() :: [Project.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Removes `name` from the registry.
  """
  @spec unregister(String.t()) :: :ok | {:error, error()}
  def unregister(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl GenServer
  def handle_call({:register, %Project{name: name} = project}, _from, state) do
    if Map.has_key?(state.projects, name) do
      {:reply, {:error, {:duplicate, name}}, state}
    else
      :ok = ensure_project_queue(project)
      {:reply, :ok, put_in(state.projects[name], project)}
    end
  end

  def handle_call({:lookup, name}, _from, state) do
    case Map.fetch(state.projects, name) do
      {:ok, project} -> {:reply, {:ok, project}, state}
      :error -> {:reply, {:error, {:unknown_project, name}}, state}
    end
  end

  def handle_call(:list, _from, state) do
    projects = state.projects |> Map.values() |> Enum.sort_by(& &1.name)
    {:reply, projects, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    case Map.pop(state.projects, name) do
      {nil, _} -> {:reply, {:error, {:unknown_project, name}}, state}
      {_project, projects} -> {:reply, :ok, %{state | projects: projects}}
    end
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{projects: %{}}}
  end

  @spec build_project(keyword() | map()) :: {:ok, Project.t()} | {:error, error()}
  defp build_project(entry) when is_list(entry), do: build_project(Map.new(entry))

  defp build_project(%{} = entry) do
    with {:ok, name} <- fetch_required(entry, :name),
         {:ok, source} <- fetch_source(entry),
         {:ok, check_stack} <- fetch_check_stack(entry),
         {:ok, roadmap_path} <- fetch_roadmap_path(entry) do
      {:ok,
       %Project{
         name: name,
         source: source,
         check_stack: check_stack,
         roadmap_path: roadmap_path,
         concurrency_cap: Map.get(entry, :concurrency_cap),
         pollution_allowlist: Map.get(entry, :pollution_allowlist)
       }}
    end
  end

  @spec ensure_project_queue(Project.t()) :: :ok
  defp ensure_project_queue(%Project{} = project) do
    case Harness.Oban.ensure_project_queue(project) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness project registry: failed to start Oban queue for #{project.name}: #{inspect(reason)}")
        :ok
    end
  end

  @spec fetch_required(map(), atom()) :: {:ok, term()} | {:error, {:invalid_project, term()}}
  defp fetch_required(entry, key) do
    case Map.fetch(entry, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:invalid_project, {:missing, key}}}
    end
  end

  @spec fetch_source(map()) :: {:ok, Project.source()} | {:error, {:invalid_project, term()}}
  defp fetch_source(entry) do
    case Map.fetch(entry, :source) do
      {:ok, {:local, path}} when is_binary(path) -> {:ok, {:local, Path.expand(path)}}
      {:ok, {:github, url}} when is_binary(url) -> {:ok, {:github, url}}
      {:ok, other} -> {:error, {:invalid_project, {:unsupported_source, other}}}
      :error -> {:error, {:invalid_project, {:missing, :source}}}
    end
  end

  @spec fetch_check_stack(map()) :: {:ok, CheckStack.t()} | {:error, {:invalid_project, term()}}
  defp fetch_check_stack(entry) do
    cond do
      match?(%CheckStack{}, Map.get(entry, :check_stack)) ->
        {:ok, Map.fetch!(entry, :check_stack)}

      # `is_atom(nil)` is true, so the previous `is_atom(Map.get(...))` form
      # falsely matched when :preset was missing. Match an explicit non-nil atom.
      is_atom(Map.get(entry, :preset)) and not is_nil(Map.get(entry, :preset)) ->
        Preset.fetch(Map.fetch!(entry, :preset))

      true ->
        {:error, {:invalid_project, {:missing, :check_stack}}}
    end
  end

  @spec fetch_roadmap_path(map()) :: {:ok, String.t()} | {:error, {:invalid_project, term()}}
  defp fetch_roadmap_path(entry) do
    case Map.fetch(entry, :roadmap_path) do
      {:ok, path} when is_binary(path) -> {:ok, Path.expand(path)}
      {:ok, other} -> {:error, {:invalid_project, {:invalid_roadmap_path, other}}}
      :error -> {:error, {:invalid_project, {:missing, :roadmap_path}}}
    end
  end
end
