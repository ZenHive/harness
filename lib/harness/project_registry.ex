defmodule Harness.ProjectRegistry do
  @moduledoc """
  Registry of `%Harness.Project{}` records.

  Projects can be registered at runtime via `register/1`. When `:repo_enabled`
  is true, runtime registrations are persisted to Postgres and restored at boot;
  `config :harness, :projects` is a one-time first-boot seed for missing names.
  Once a row exists, the Postgres row wins. When repo persistence is disabled,
  config projects remain the ephemeral bootstrap.

  ## Effective projects — the single landing-policy read boundary

  `lookup/1` and `list/0` return the **landing-overlaid effective project**:
  `landing_policy` / `target_branch` / `reviewer` reflect the operator's
  runtime overrides in `Harness.Landing.Settings` (the `harness_settings[:landing]`
  store), never the stale value persisted in the projects payload. The persisted
  payload's landing fields are a *registration-time seed* only — a project with no
  override returns its registration default unchanged.

  This is THE single place the overlay is applied. Callers must not re-overlay a
  looked-up struct (the old per-call-site `Landing.Settings.overlay/1` in
  `Harness.Run` / `Harness.Lander.Worker` is gone). Task 171 was a point-fix of one
  forgetful call site; overlaying here makes "forgetting" structurally impossible.
  """

  use GenServer
  use Descripex, namespace: "/project_registry"

  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Project
  alias Harness.ProjectRegistry.Persistence

  require Logger

  @default_queue_limit 1

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
    restored_projects = load_projects()

    Enum.each(restored_projects, &ensure_project_queue/1)

    {:ok, %{projects: projects_map(restored_projects)}}
  end

  api(
    :register,
    "Register a project struct under its name. When :repo_enabled, survives a BEAM restart via Postgres; config :harness, :projects only seeds missing rows on first boot.",
    params: [
      project: [
        # A %Harness.Project{} struct a stateless JSON caller cannot construct —
        # so this stays off the MCP/chat surface (Harness.Manifest drops
        # :exchange_data tools). JSON orchestrators register via the flat
        # scalar tool Harness.Dispatch.register_project/8 (dispatch-register_project),
        # which builds the struct through this module's validated builder.
        kind: :exchange_data,
        source: "Harness.Dispatch.register_project/8 (the JSON-native scalar entry point)",
        description:
          "%Harness.Project{} the caller constructs (name, source, check_command, language, roadmap_path, concurrency_cap, pollution_allowlist, warm_paths)."
      ]
    ],
    returns: %{
      type: :tuple,
      description: ":ok on success. {:error, {:duplicate, name}} when the slug is already taken."
    }
  )

  @spec register(Project.t() | keyword() | map()) :: :ok | {:error, error()}
  def register(%Project{} = project) do
    GenServer.call(__MODULE__, {:register, project})
  end

  # In-process convenience: build a validated %Project{} from attrs (keyword or
  # map) and register it. Shares fetch/validation/path-expansion with
  # config-declared projects via build_project/1, so a runtime registration
  # behaves identically to a config entry. This is the path the JSON-native
  # Harness.Dispatch.register_project/8 routes through.
  def register(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, project} <- build_project(attrs) do
      register(project)
    end
  end

  api(
    :upsert,
    "Replace or insert a project registration under its name. Updates the in-memory registry, persists the row when :repo_enabled, and ensures/scales the project's Oban queues.",
    params: [
      project: [
        kind: :exchange_data,
        source: "Harness.ProjectRegistry.upsert/1 attrs map or Harness.Dispatch scalar tools",
        description:
          "%Harness.Project{} or attrs (name, source, roadmap_path, check_command, language, concurrency_cap, pollution_allowlist, warm_paths)."
      ]
    ],
    returns: %{
      type: :tuple,
      description: ":ok on success. {:error, {:invalid_project, reason}} when attrs cannot build a project."
    }
  )

  @spec upsert(Project.t() | keyword() | map()) :: :ok | {:error, error()}
  def upsert(%Project{} = project) do
    GenServer.call(__MODULE__, {:upsert, project})
  end

  def upsert(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, project} <- build_project(attrs) do
      upsert(project)
    end
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
    case GenServer.call(__MODULE__, {:lookup, name}) do
      {:ok, project} -> {:ok, LandingSettings.overlay(project)}
      error -> error
    end
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
    __MODULE__
    |> GenServer.call(:list)
    |> Enum.map(&LandingSettings.overlay/1)
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

  def handle_call({:upsert, %Project{name: name} = project}, _from, state) do
    previous = Map.get(state.projects, name)

    :ok = Persistence.upsert(project)
    :ok = sync_project_queue(previous, project)

    {:reply, :ok, put_in(state.projects[name], project)}
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
    restored_projects = load_projects()

    Enum.each(restored_projects, &ensure_project_queue/1)

    {:reply, :ok, %{projects: projects_map(restored_projects)}}
  end

  @spec load_projects() :: [Project.t()]
  defp load_projects do
    warn_shadowed_config_projects()

    config_projects = load_config_projects()

    if Persistence.enabled?() do
      persisted_projects = Persistence.list()
      import_missing_config_projects(config_projects, persisted_projects)
      Persistence.list()
    else
      Map.values(config_projects)
    end
  end

  @spec projects_map([Project.t()]) :: %{String.t() => Project.t()}
  defp projects_map(projects) do
    Map.new(projects, fn %Project{name: name} = project -> {name, project} end)
  end

  @spec build_project(keyword() | map()) :: {:ok, Project.t()} | {:error, error()}
  defp build_project(entry) when is_list(entry), do: build_project(Map.new(entry))

  defp build_project(%{} = entry) do
    with {:ok, name} <- fetch_required(entry, :name),
         {:ok, source} <- fetch_source(entry),
         {:ok, roadmap_path} <- fetch_roadmap_path(entry),
         {:ok, check_command} <- fetch_check_command(entry),
         {:ok, language} <- fetch_language(entry) do
      {:ok,
       %Project{
         name: name,
         source: source,
         roadmap_path: roadmap_path,
         check_command: check_command,
         language: language,
         concurrency_cap: Map.get(entry, :concurrency_cap),
         pollution_allowlist: Map.get(entry, :pollution_allowlist),
         warm_paths: Map.get(entry, :warm_paths, []),
         landing_policy: Map.get(entry, :landing_policy, :manual),
         target_branch: Map.get(entry, :target_branch),
         reviewer: Map.get(entry, :reviewer),
         test_db_isolation_env: Map.get(entry, :test_db_isolation_env)
       }}
    end
  end

  @spec load_config_projects() :: %{String.t() => Project.t()}
  defp load_config_projects do
    :harness
    |> configured_project_entries()
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

  @spec warn_shadowed_config_projects() :: :ok
  defp warn_shadowed_config_projects do
    if Persistence.enabled?() and configured_project_entries(:harness) != [] do
      Logger.warning(
        "harness project registry: config projects are seed-only and shadowed by the Postgres projects table; edit projects live in /harness/settings or upsert fresh/reset databases with priv/repo/seeds.exs via mix harness.seed"
      )
    end

    :ok
  end

  @spec configured_project_entries(atom()) :: [term()]
  defp configured_project_entries(app) do
    Application.get_env(app, :projects, [])
  end

  @spec import_missing_config_projects(%{String.t() => Project.t()}, [Project.t()]) :: :ok
  defp import_missing_config_projects(config_projects, persisted_projects) do
    persisted_names = MapSet.new(persisted_projects, & &1.name)

    config_projects
    |> Map.values()
    |> Enum.reject(&MapSet.member?(persisted_names, &1.name))
    |> Enum.each(&Persistence.upsert/1)
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

  @spec sync_project_queue(Project.t() | nil, Project.t()) :: :ok
  defp sync_project_queue(nil, %Project{} = project), do: ensure_project_queue(project)

  defp sync_project_queue(%Project{} = previous, %Project{} = project) do
    :ok = ensure_project_queue(project)

    if queue_limit(previous) == queue_limit(project) do
      :ok
    else
      scale_project_queue(project)
    end
  end

  @spec scale_project_queue(Project.t()) :: :ok
  defp scale_project_queue(%Project{} = project) do
    if queues_enabled?() and oban_running?() do
      case Oban.scale_queue(Harness.Oban,
             queue: Harness.Oban.queue_name(project),
             limit: queue_limit(project),
             local_only: true
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("harness project registry: failed to scale Oban queue for #{project.name}: #{inspect(reason)}")

          :ok
      end
    else
      :ok
    end
  end

  @spec oban_running?() :: boolean()
  defp oban_running? do
    is_pid(Oban.whereis(Harness.Oban))
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

  @spec fetch_language(map()) :: {:ok, atom() | nil} | {:error, {:invalid_project, term()}}
  defp fetch_language(entry) do
    case Map.get(entry, :language) do
      nil -> {:ok, nil}
      language when is_atom(language) -> {:ok, language}
      other -> {:error, {:invalid_project, {:invalid_language, other}}}
    end
  end
end
