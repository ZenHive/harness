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

  The overlay is applied from a registry-held snapshot of that settings row,
  loaded at boot and refreshed when `Landing.Settings` writes (or on `reset/0` /
  `reload_persisted_state/0`). Repeated `lookup/1` does not re-fetch Postgres.
  The store remains the persisted source of truth.

  This is THE single place the overlay is applied. Callers must not re-overlay a
  looked-up struct (the old per-call-site `Landing.Settings.overlay/1` in
  `Harness.Run` / `Harness.Lander.Worker` is gone). Task 171 was a point-fix of one
  forgetful call site; overlaying here makes "forgetting" structurally impossible.

  ## Optional fields are type-checked at every registration seam

  `register/1` and `upsert/1` (attrs map or `%Project{}`) and config-seeded
  entries reject a value that does not match `%Harness.Project{}`'s `@type`:
  `concurrency_cap`, `landing_policy`, `target_branch`, `reviewer`,
  `pollution_allowlist`, `warm_paths`, `test_db_isolation_env`,
  `tooling_baseline_overrides`. A string `"4"` for `concurrency_cap` is never
  persisted. An already-persisted row that violates a type is skipped at load
  rather than handed to callers.
  """

  use GenServer
  use Descripex, namespace: "/project_registry"

  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Project
  alias Harness.ProjectRegistry.OptionalFields
  alias Harness.ProjectRegistry.Persistence

  require Logger

  @known_languages ~w(elixir rust javascript typescript go)a

  @type error ::
          {:duplicate, String.t()} | {:unknown_project, String.t()} | {:invalid_project, term()}

  @typep state :: %{
           projects: %{String.t() => Project.t()},
           landing_overrides: LandingSettings.t()
         }

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
  @spec init(term()) :: {:ok, state()}
  def init(_init_arg) do
    restored_projects = load_projects()

    Enum.each(restored_projects, &ensure_project_queue/1)

    {:ok, new_state(restored_projects)}
  end

  api(
    :register,
    "Register a project struct under its name. Persists to Postgres by default (:repo_enabled defaults to true) and survives a BEAM restart. Set repo_enabled: false for ephemeral in-memory registration. config :harness, :projects only seeds missing rows on first boot.",
    params: [
      project: [
        # A %Harness.Project{} struct a stateless JSON caller cannot construct —
        # so this stays off the MCP/chat surface (Harness.Manifest drops
        # :exchange_data tools). JSON orchestrators register via the flat
        # scalar tool Harness.Dispatch.register_project/9 (dispatch-register_project),
        # which builds the struct through this module's validated builder.
        kind: :exchange_data,
        source: "Harness.Dispatch.register_project/9 (the JSON-native scalar entry point)",
        description:
          "%Harness.Project{} the caller constructs (name, source, check_command, languages, roadmap_path, roadmap_target_branch, concurrency_cap, pollution_allowlist, warm_paths)."
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
  # Harness.Dispatch.register_project/9 routes through.
  def register(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, project} <- build_project(attrs) do
      register(project)
    end
  end

  api(
    :upsert,
    "Replace or insert a project registration under its name. Updates the in-memory registry, persists the row by default (:repo_enabled defaults to true), and ensures/scales the project's Oban queues. Set repo_enabled: false for ephemeral in-memory registration.",
    params: [
      project: [
        kind: :exchange_data,
        source: "Harness.ProjectRegistry.upsert/1 attrs map or Harness.Dispatch scalar tools",
        description:
          "%Harness.Project{} or attrs (name, source, roadmap_path, roadmap_target_branch, check_command, languages, concurrency_cap, pollution_allowlist, warm_paths)."
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
  @spec refresh_landing_overrides() :: :ok
  def refresh_landing_overrides do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :refresh_landing_overrides)
      nil -> :ok
    end
  end

  @doc false
  @impl GenServer
  def handle_call({:register, %Project{name: name} = project}, _from, state) do
    case validate_project(project) do
      :ok ->
        if Map.has_key?(state.projects, name) do
          {:reply, {:error, {:duplicate, name}}, state}
        else
          :ok = ensure_project_queue(project)
          :ok = Persistence.upsert(project)
          {:reply, :ok, put_in(state.projects[name], project)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:upsert, %Project{name: name} = project}, _from, state) do
    case validate_project(project) do
      :ok ->
        previous = Map.get(state.projects, name)

        :ok = Persistence.upsert(project)
        :ok = sync_project_queue(previous, project)

        {:reply, :ok, put_in(state.projects[name], project)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, name}, _from, state) do
    case Map.fetch(state.projects, name) do
      {:ok, project} ->
        {:reply, {:ok, LandingSettings.overlay(project, state.landing_overrides)}, state}

      :error ->
        {:reply, {:error, {:unknown_project, name}}, state}
    end
  end

  def handle_call(:list, _from, state) do
    projects =
      state.projects
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> LandingSettings.overlay_many(state.landing_overrides)

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
    {:reply, :ok, new_state([])}
  end

  def handle_call(:reload_persisted_state, _from, _state) do
    restored_projects = load_projects()

    Enum.each(restored_projects, &ensure_project_queue/1)

    {:reply, :ok, new_state(restored_projects)}
  end

  def handle_call(:refresh_landing_overrides, _from, state) do
    {:reply, :ok, %{state | landing_overrides: LandingSettings.overrides()}}
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

  @spec new_state([Project.t()]) :: state()
  defp new_state(projects) do
    %{projects: projects_map(projects), landing_overrides: LandingSettings.overrides()}
  end

  @spec build_project(keyword() | map()) :: {:ok, Project.t()} | {:error, error()}
  defp build_project(entry) when is_list(entry), do: build_project(Map.new(entry))

  defp build_project(%{} = entry) do
    with {:ok, name} <- fetch_required(entry, :name),
         {:ok, source} <- fetch_source(entry),
         {:ok, roadmap_path} <- fetch_roadmap_path(entry),
         {:ok, roadmap_target_branch} <- fetch_roadmap_target_branch(entry),
         {:ok, check_command} <- fetch_check_command(entry),
         {:ok, languages} <- fetch_languages(entry),
         {:ok, optional} <- OptionalFields.fetch(entry) do
      {:ok,
       struct(
         Project,
         Map.merge(optional, %{
           name: name,
           source: source,
           roadmap_path: roadmap_path,
           roadmap_target_branch: roadmap_target_branch,
           check_command: check_command,
           languages: languages
         })
       )}
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

    if Harness.Oban.queue_limit(previous) == Harness.Oban.queue_limit(project) do
      :ok
    else
      scale_project_queue(project)
    end
  end

  @spec scale_project_queue(Project.t()) :: :ok
  defp scale_project_queue(%Project{} = project) do
    if Harness.Oban.queues_enabled?() and oban_running?() do
      case Oban.scale_queue(Harness.Oban,
             queue: Harness.Oban.queue_name(project),
             limit: Harness.Oban.queue_limit(project),
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

  @spec fetch_roadmap_target_branch(map()) ::
          {:ok, String.t() | nil} | {:error, {:invalid_project, term()}}
  defp fetch_roadmap_target_branch(entry) do
    case Map.get(entry, :roadmap_target_branch) do
      nil -> {:ok, nil}
      branch when is_binary(branch) -> validate_roadmap_target_branch_value(branch)
      other -> {:error, {:invalid_project, {:invalid_roadmap_target_branch, other}}}
    end
  end

  @spec validate_roadmap_target_branch_value(String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_project, term()}}
  defp validate_roadmap_target_branch_value(branch) do
    if valid_branch_name?(branch),
      do: {:ok, branch},
      else: {:error, {:invalid_project, {:invalid_roadmap_target_branch, branch}}}
  end

  # `check_command` is a free-text hint the reviewer AI receives in its prompt
  # (e.g. "mix check.dispatch"). Optional — a project without one leaves the reviewer
  # to discover the project's checks itself. Harness never executes it.
  @spec fetch_check_command(map()) :: {:ok, String.t() | nil} | {:error, {:invalid_project, term()}}
  defp fetch_check_command(entry) do
    case Map.get(entry, :check_command) do
      nil -> {:ok, nil}
      command when is_binary(command) -> {:ok, command}
      other -> {:error, {:invalid_project, {:invalid_check_command, other}}}
    end
  end

  @spec validate_project(Project.t()) :: :ok | {:error, {:invalid_project, term()}}
  defp validate_project(%Project{languages: languages, roadmap_target_branch: branch} = project) do
    with {:ok, ^languages} <- validate_languages(languages),
         :ok <- validate_roadmap_target_branch(branch),
         :ok <- OptionalFields.validate(project) do
      :ok
    else
      {:ok, _normalized} -> {:error, {:invalid_project, {:invalid_languages, languages}}}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_roadmap_target_branch(term()) :: :ok | {:error, {:invalid_project, term()}}
  defp validate_roadmap_target_branch(nil), do: :ok

  defp validate_roadmap_target_branch(branch) when is_binary(branch) do
    if valid_branch_name?(branch),
      do: :ok,
      else: {:error, {:invalid_project, {:invalid_roadmap_target_branch, branch}}}
  end

  defp validate_roadmap_target_branch(other), do: {:error, {:invalid_project, {:invalid_roadmap_target_branch, other}}}

  @spec valid_branch_name?(String.t()) :: boolean()
  defp valid_branch_name?(branch) do
    case System.find_executable("git") do
      nil -> false
      _path -> match?({_output, 0}, System.cmd("git", ["check-ref-format", "--branch", branch], stderr_to_stdout: true))
    end
  end

  @spec fetch_languages(map()) :: {:ok, [atom(), ...]} | {:error, {:invalid_project, term()}}
  defp fetch_languages(entry) do
    case Map.fetch(entry, :languages) do
      {:ok, languages} -> validate_languages(languages)
      :error -> {:error, {:invalid_project, {:missing, :languages}}}
    end
  end

  @spec validate_languages(term()) :: {:ok, [atom(), ...]} | {:error, {:invalid_project, term()}}
  defp validate_languages([_ | _] = languages) do
    case Enum.reduce_while(languages, {:ok, []}, &normalize_language/2) do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, {:invalid_project, reason}}
    end
  end

  defp validate_languages([]), do: {:error, {:invalid_project, {:empty, :languages}}}

  # Belt-and-braces for MCP clients that stringify a list argument when the
  # schema is typeless. A bare language string is still rejected.
  defp validate_languages(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, decoded} when is_list(decoded) -> validate_languages(decoded)
      _other -> {:error, {:invalid_project, {:invalid_languages, encoded}}}
    end
  end

  defp validate_languages(other), do: {:error, {:invalid_project, {:invalid_languages, other}}}

  @spec normalize_language(term(), {:ok, [atom()]}) :: {:cont, {:ok, [atom()]}} | {:halt, {:error, term()}}
  defp normalize_language(:mixed, _acc), do: {:halt, {:error, {:invalid_languages, :mixed}}}

  defp normalize_language(language, {:ok, acc}) when is_atom(language) do
    {:cont, {:ok, [language | acc]}}
  end

  defp normalize_language(language, {:ok, acc}) when is_binary(language) do
    case language_atom(language) do
      nil -> {:halt, {:error, {:invalid_languages, language}}}
      atom -> {:cont, {:ok, [atom | acc]}}
    end
  end

  defp normalize_language(language, _acc), do: {:halt, {:error, {:invalid_languages, language}}}

  @spec language_atom(String.t()) :: atom() | nil
  defp language_atom(language) do
    Enum.find(@known_languages, &(Atom.to_string(&1) == language))
  end
end
