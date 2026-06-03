defmodule Harness.ProjectRegistry do
  @moduledoc """
  Registry of `%Harness.Project{}` records.

  Projects boot from `config :harness, :projects` and can be registered at
  runtime via `register/1`. When `:repo_enabled` is true, runtime registrations
  are persisted to Postgres and restored at boot; config-declared projects win on
  name conflict.
  """

  use GenServer
  use Descripex, namespace: "/project_registry"

  alias Harness.Project
  alias Harness.ProjectRegistry.Persistence

  require Logger

  @type error ::
          {:duplicate, String.t()} | {:unknown_project, String.t()} | {:invalid_project, term()}

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [init_arg]}}
  end

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc false
  @impl GenServer
  @spec init(term()) :: {:ok, %{projects: %{String.t() => Project.t()}}}
  def init(_init_arg) do
    config_projects = load_config_projects()
    restored_projects = load_persisted_projects(config_projects)

    Enum.each(restored_projects, &ensure_project_queue/1)

    projects =
      Enum.reduce(restored_projects, config_projects, fn project, acc ->
        Map.put(acc, project.name, project)
      end)

    {:ok, %{projects: projects}}
  end

  api(
    :register,
    "Register a project struct under its name. When :repo_enabled, survives a BEAM restart via Postgres; config :harness, :projects always wins on name conflict.",
    params: [
      project: [
        kind: :value,
        description:
          "%Harness.Project{} the caller constructs (name, source, check_command, roadmap_path, concurrency_cap, pollution_allowlist)."
      ]
    ],
    returns: %{
      type: :tuple,
      description: ":ok on success. {:error, {:duplicate, name}} when the slug is already taken."
    }
  )

  @spec register(Project.t()) :: :ok | {:error, error()}
  def register(%Project{} = project) do
    GenServer.call(__MODULE__, {:register, project})
  end

  api(:lookup, "Look up a registered project by name slug.",
    params: [
      name: [
        kind: :value,
        description: ~s{Project slug string (e.g. "harness", "myapp").}
      ]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, %Harness.Project{}} or {:error, {:unknown_project, name}}."
    }
  )

  @spec lookup(String.t()) :: {:ok, Project.t()} | {:error, error()}
  def lookup(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:lookup, name})
  end

  api(:list, "List every registered project, sorted by name.",
    returns: %{
      type: :list,
      description:
        "List of %Harness.Project{} structs. Source-of-truth for the chat orchestrator's project switcher and dispatch lookups."
    }
  )

  @spec list() :: [Project.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  api(:unregister, "Remove a project from the registry by name.",
    params: [
      name: [kind: :value, description: "Project slug to remove."]
    ],
    returns: %{
      type: :tuple,
      description: ":ok on success. {:error, {:unknown_project, name}} when the slug was not registered."
    }
  )

  @spec unregister(String.t()) :: :ok | {:error, error()}
  def unregister(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc false
  @spec reload_persisted_state() :: :ok
  def reload_persisted_state do
    GenServer.call(__MODULE__, :reload_persisted_state)
  end

  @doc false
  @impl GenServer
  def handle_call({:register, %Project{name: name} = project}, _from, state) do
    if Map.has_key?(state.projects, name) do
      {:reply, {:error, {:duplicate, name}}, state}
    else
      :ok = ensure_project_queue(project)
      :ok = Persistence.upsert(project)
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
      {nil, _} ->
        {:reply, {:error, {:unknown_project, name}}, state}

      {_project, projects} ->
        :ok = Persistence.delete(name)
        {:reply, :ok, %{state | projects: projects}}
    end
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{projects: %{}}}
  end

  def handle_call(:reload_persisted_state, _from, _state) do
    config_projects = load_config_projects()
    restored_projects = load_persisted_projects(config_projects)

    Enum.each(restored_projects, &ensure_project_queue/1)

    projects =
      Enum.reduce(restored_projects, config_projects, fn project, acc ->
        Map.put(acc, project.name, project)
      end)

    {:reply, :ok, %{projects: projects}}
  end

  @spec build_project(keyword() | map()) :: {:ok, Project.t()} | {:error, error()}
  defp build_project(entry) when is_list(entry), do: build_project(Map.new(entry))

  defp build_project(%{} = entry) do
    with {:ok, name} <- fetch_required(entry, :name),
         {:ok, source} <- fetch_source(entry),
         {:ok, roadmap_path} <- fetch_roadmap_path(entry),
         {:ok, check_command} <- fetch_check_command(entry) do
      {:ok,
       %Project{
         name: name,
         source: source,
         roadmap_path: roadmap_path,
         check_command: check_command,
         concurrency_cap: Map.get(entry, :concurrency_cap),
         pollution_allowlist: Map.get(entry, :pollution_allowlist),
         landing_policy: Map.get(entry, :landing_policy, :manual),
         target_branch: Map.get(entry, :target_branch)
       }}
    end
  end

  @spec load_config_projects() :: %{String.t() => Project.t()}
  defp load_config_projects do
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
  end

  @spec load_persisted_projects(%{String.t() => Project.t()}) :: [Project.t()]
  defp load_persisted_projects(config_projects) do
    Enum.reject(Persistence.list(), fn %Project{name: name} -> Map.has_key?(config_projects, name) end)
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

  @spec fetch_roadmap_path(map()) :: {:ok, String.t()} | {:error, {:invalid_project, term()}}
  defp fetch_roadmap_path(entry) do
    case Map.fetch(entry, :roadmap_path) do
      {:ok, path} when is_binary(path) -> {:ok, Path.expand(path)}
      {:ok, other} -> {:error, {:invalid_project, {:invalid_roadmap_path, other}}}
      :error -> {:error, {:invalid_project, {:missing, :roadmap_path}}}
    end
  end

  # `check_command` is a free-text hint the reviewer AI receives in its prompt
  # (e.g. "mix precommit"). Optional — a project without one leaves the reviewer
  # to discover the project's checks itself. Harness never executes it.
  @spec fetch_check_command(map()) :: {:ok, String.t() | nil} | {:error, {:invalid_project, term()}}
  defp fetch_check_command(entry) do
    case Map.get(entry, :check_command) do
      nil -> {:ok, nil}
      command when is_binary(command) -> {:ok, command}
      other -> {:error, {:invalid_project, {:invalid_check_command, other}}}
    end
  end
end
