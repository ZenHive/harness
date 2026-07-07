defmodule Harness.Config do
  @moduledoc """
  Declarative schema + read/write accessor for the harness node's operator config
  (Task 167).

  Centralizes the operator-relevant `:harness` application-env keys that were
  scattered as bare `Application.get_env/3` reads with their defaults duplicated
  across module attributes and the config inspector. Every entry declares its
  app-env `key` path, baked-in `default`, value `type`, overriding `env_var`, and
  the `ui_editable?` / `restart_required?` flags — so defaults live in exactly one
  place (`schema/0`) and the dashboard can render both a read-only inspector and an
  editable card from the same source.

  ## App env is the live cache; SettingsStore is the persistence layer

  Unlike the on/off settings domains (`Harness.Cron.Settings`,
  `Harness.Agent.Settings`, `Harness.Landing.Settings`, which read the Postgres
  store directly), this richer schema keeps an app-env live cache for its
  env-var-wins / restart-required semantics: `get/1` reads the value already
  folded into app env (compile-time default → `config.exs` → `runtime.exs` env
  var → persisted UI override). `put/3` validates against the schema,
  write-throughs to `Harness.SettingsStore`, and — unless the key is
  `restart_required?` — applies
  the value to app env live, so a run timeout edit takes effect on the next run
  with no restart. `load_into_env/0` runs once on boot to re-apply persisted
  overrides.

  ## Env var wins over a persisted UI override

  A key whose `env_var` is set in the environment is left untouched by
  `load_into_env/0` — the deployment env var is authoritative, matching the
  inspector's `env > config > default` provenance order. So a stale UI override
  never silently shadows an operator's `HARNESS_*` setting.

  ## Restart-required keys are persisted, not hot-applied

  `restart_required?` keys (e.g. the dashboard port, bound by the endpoint at
  boot) are persisted by `put/3` but **not** applied to app env live — the running
  value is unchanged until the next boot, when `load_into_env/0` seeds the
  persisted value. The dashboard labels these so the operator knows the edit is
  deferred.
  """

  use Descripex, namespace: "/config"

  alias Harness.Config.Entry
  alias Harness.SettingsStore

  require Logger

  @store_key :config
  @hours_per_day 24
  @default_transcript_retention_days 30
  @default_transcript_retention_ms to_timeout(hour: @hours_per_day) * @default_transcript_retention_days

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary, type: :worker}
  end

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    load_into_env()
    :ignore
  end

  # The implementer agents an unassigned task may default-route to — the closed
  # set the `:agent`-typed `{:dispatch, :default_agent}` key validates against and
  # the dashboard select renders. Mirrors `Harness.Roadmap`'s `@valid_agents`
  # (minus `:human`, which is never an autonomous dispatch target).
  @implementer_agents [:claude, :codex, :cursor, :grok, :antigravity, :pi]

  @doc false
  @spec schema() :: [Entry.t()]
  def schema do
    [
      e("Dashboard", "enabled", {:dashboard, :enabled}, true, :boolean, restart_required?: true),
      e("Dashboard", "port", {:dashboard, :port}, 4018, :integer,
        env_var: "HARNESS_DASHBOARD_PORT",
        ui_editable?: true,
        restart_required?: true
      ),
      e("Dashboard", "secret_key_base", {Harness.Dashboard.Endpoint, :secret_key_base}, nil, :string,
        env_var: "HARNESS_SECRET_KEY_BASE",
        restart_required?: true,
        secret?: true
      ),
      e("Run timeouts", "total_timeout", {:run, :total_timeout}, nil, :duration_ms, ui_editable?: true),
      e("Run timeouts", "idle_timeout", {:run, :idle_timeout}, nil, :duration_ms, ui_editable?: true),
      e("Run timeouts", "lifetime_timeout", {:run, :lifetime_timeout}, 5_400_000, :duration_ms, ui_editable?: true),
      e("Run timeouts", "max_hold_timeout", {:run, :max_hold_timeout}, 1_800_000, :duration_ms, ui_editable?: true),
      e("Run timeouts", "terminal_linger", {:run, :terminal_linger}, 5_000, :duration_ms, ui_editable?: true),
      e("Run timeouts", "reviewer_spawn_timeout", {:run, :reviewer_spawn_timeout}, 60_000, :duration_ms,
        ui_editable?: true
      ),
      e("Dispatch", "default_agent", {:dispatch, :default_agent}, :codex, :agent, ui_editable?: true),
      e("Notifications", "sinks", :notification_sinks, [], :atom_list),
      e("Paths", "project cache_root", {:project, :cache_root}, Path.expand("~/_DATA/harness/projects"), :path),
      e("Worktree", "base_dir", {:worktree, :base_dir}, Path.expand("~/_DATA/worktrees/.harness"), :path,
        env_var: "HARNESS_WORKTREE_ROOT"
      ),
      e("Worktree", "retain_on_failure", {:worktree, :retain_on_failure}, true, :boolean),
      e("Worktree", "sweep_on_boot", {:worktree, :sweep_on_boot}, true, :boolean),
      e("Retry policy", "max_retries", {:retry_policy, :max_retries}, 3, :integer),
      e("Retry policy", "base_delay_ms", {:retry_policy, :base_delay_ms}, 1_000, :duration_ms),
      e("Retry policy", "max_delay_ms", {:retry_policy, :max_delay_ms}, 60_000, :duration_ms),
      e("Retry policy", "multiplier", {:retry_policy, :multiplier}, 2.0, :float),
      e(
        "ResultStore",
        "transcript_retention_ms",
        {:run_records, :transcript_retention_ms},
        @default_transcript_retention_ms,
        :duration_ms,
        ui_editable?: true
      ),
      e("Database", "database", {Harness.Repo, :database}, nil, :string, env_var: "HARNESS_DB_NAME"),
      e("Database", "username", {Harness.Repo, :username}, nil, :string, env_var: "HARNESS_DB_USER"),
      e("Database", "hostname", {Harness.Repo, :hostname}, nil, :string, env_var: "HARNESS_DB_HOST")
    ] ++ agent_model_entries() ++ reviewer_model_entries()
  end

  # One free-text default-model pin per implementer agent — the fallback layer
  # between a task's explicit `model` and the agent CLI's own ambient default
  # (see `agent_model/1`). Free-text `:string` because model ids churn; `nil`
  # (unset) falls through to the CLI default. Operator preferences are seeded via
  # priv/repo/seeds.exs rather than the schema default so tests see nil.
  @spec agent_model_entries() :: [Entry.t()]
  defp agent_model_entries do
    Enum.map(@implementer_agents, fn agent ->
      e("Agent models", Atom.to_string(agent), {:agent_model, agent}, nil, :string, ui_editable?: true)
    end)
  end

  # Optional per-role reviewer model pins. Unset inherits the shared per-agent
  # default so existing configs keep today's reviewer behavior until overridden.
  @spec reviewer_model_entries() :: [Entry.t()]
  defp reviewer_model_entries do
    Enum.map(@implementer_agents, fn agent ->
      label = "#{String.capitalize(Atom.to_string(agent))} reviewer"
      e("Reviewer models", label, {:reviewer_model, agent}, nil, :string, ui_editable?: true)
    end)
  end

  @doc false
  @spec editable_entries() :: [Entry.t()]
  def editable_entries, do: Enum.filter(schema(), & &1.ui_editable?)

  @doc false
  @spec dispatch_agents() :: [atom()]
  def dispatch_agents, do: @implementer_agents

  @doc false
  @spec agent_model(atom()) :: String.t() | nil
  def agent_model(agent) when is_atom(agent) do
    case fetch_entry({:agent_model, agent}) do
      {:ok, entry} -> blank_to_nil(read_env(entry.key, entry.default))
      :error -> nil
    end
  end

  @doc false
  @spec reviewer_model(atom()) :: String.t() | nil
  def reviewer_model(agent) when is_atom(agent) do
    case fetch_entry({:reviewer_model, agent}) do
      {:ok, entry} -> blank_to_nil(read_env(entry.key, entry.default)) || agent_model(agent)
      :error -> agent_model(agent)
    end
  end

  @spec blank_to_nil(term()) :: term()
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @doc """
  Resolves a schema key's effective value from app env, falling back to the
  schema default. Raises on an unknown key (a typo is a programming error, not a
  runtime condition). This is the read path code uses instead of a raw
  `Application.get_env/3` for schema-covered keys.
  """
  api(:get, "Return one operator config entry by dotted key, with secrets redacted.",
    params: [
      key: [
        kind: :value,
        description: ~s(Dotted config key from config-list, e.g. "run.idle_timeout" or "agent_model.codex".),
        schema: String.t()
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{group, label, key, value, default, editable, restart_required, env_var, secret}} or {:error, {:unknown_key, key}}."
    }
  )

  @spec get(Entry.key() | String.t()) :: term() | {:ok, map()} | {:error, {:unknown_key, String.t()}}
  def get(key) when is_binary(key), do: get_config(key)

  def get(key) do
    case fetch_entry(key) do
      {:ok, entry} -> read_env(entry.key, entry.default)
      :error -> raise ArgumentError, "unknown config key: #{inspect(key)}"
    end
  end

  @doc false
  @spec get_config(String.t()) :: {:ok, map()} | {:error, {:unknown_key, String.t()}}
  def get_config(key) when is_binary(key) do
    case Enum.find(schema(), &(key_string(&1.key) == key)) do
      %Entry{} = entry -> {:ok, project_entry(entry)}
      nil -> {:error, {:unknown_key, key}}
    end
  end

  api(:list, "List operator config schema entries with effective values and secrets redacted.",
    returns: %{
      type: :list,
      description: "[%{group, label, key, value, default, editable, restart_required, env_var, secret}] in schema order."
    }
  )

  @spec list() :: [map()]
  def list, do: Enum.map(schema(), &project_entry/1)

  @doc false
  @spec put(Entry.key(), term(), String.t()) :: :ok | {:error, atom()}
  def put(key, value, actor) when is_binary(actor) do
    with {:ok, entry} <- fetch_editable(key),
         :ok <- validate(entry, value) do
      persist_override(key, value)
      if !entry.restart_required?, do: apply_to_env(entry.key, value)
      Logger.info("harness config: #{entry.label} set to #{inspect(value)} by #{actor}#{restart_suffix(entry)}")
      :ok
    end
  end

  @doc false
  @spec load_into_env() :: :ok
  def load_into_env do
    Enum.each(overrides(), &apply_override/1)
  end

  # ── Internals ───────────────────────────────────────────────────────────────

  @spec apply_override({Entry.key(), term()}) :: :ok
  defp apply_override({key, value}) do
    with {:ok, entry} <- fetch_entry(key),
         false <- env_var_set?(entry) do
      apply_to_env(entry.key, value)
    else
      _skip -> :ok
    end
  end

  @spec fetch_editable(Entry.key()) :: {:ok, Entry.t()} | {:error, :unknown_key | :not_editable}
  defp fetch_editable(key) do
    case fetch_entry(key) do
      {:ok, %Entry{ui_editable?: true} = entry} -> {:ok, entry}
      {:ok, %Entry{}} -> {:error, :not_editable}
      :error -> {:error, :unknown_key}
    end
  end

  @spec fetch_entry(Entry.key()) :: {:ok, Entry.t()} | :error
  defp fetch_entry(key) do
    case Enum.find(schema(), &(&1.key == key)) do
      %Entry{} = entry -> {:ok, entry}
      nil -> :error
    end
  end

  @spec validate(Entry.t(), term()) :: :ok | {:error, :invalid_value}
  defp validate(%Entry{type: :duration_ms}, value) when is_nil(value) or (is_integer(value) and value >= 0), do: :ok
  defp validate(%Entry{type: :integer}, value) when is_integer(value) and value > 0, do: :ok
  defp validate(%Entry{type: :agent}, value) when value in @implementer_agents, do: :ok
  defp validate(%Entry{type: :string}, value) when is_nil(value) or is_binary(value), do: :ok
  defp validate(_entry, _value), do: {:error, :invalid_value}

  @spec read_env(Entry.key(), term()) :: term()
  defp read_env({ns, sub}, default), do: :harness |> Application.get_env(ns, []) |> Keyword.get(sub, default)
  defp read_env(flat, default) when is_atom(flat), do: Application.get_env(:harness, flat, default)

  @spec apply_to_env(Entry.key(), term()) :: :ok
  defp apply_to_env({ns, sub}, value) do
    current = Application.get_env(:harness, ns, [])
    Application.put_env(:harness, ns, Keyword.put(current, sub, value))
  end

  defp apply_to_env(flat, value) when is_atom(flat), do: Application.put_env(:harness, flat, value)

  @spec env_var_set?(Entry.t()) :: boolean()
  defp env_var_set?(%Entry{env_var: var}) when is_binary(var), do: System.get_env(var) != nil
  defp env_var_set?(%Entry{}), do: false

  @spec restart_suffix(Entry.t()) :: String.t()
  defp restart_suffix(%Entry{restart_required?: true}), do: " (applies on restart)"
  defp restart_suffix(%Entry{}), do: ""

  @spec persist_override(Entry.key(), term()) :: :ok | {:error, term()}
  defp persist_override(key, value) do
    SettingsStore.put(@store_key, Map.put(overrides(), key, value))
  end

  @spec overrides() :: %{Entry.key() => term()}
  defp overrides do
    case SettingsStore.fetch(@store_key) do
      {:ok, map} when is_map(map) -> map
      _missing_or_invalid -> %{}
    end
  end

  @spec e(String.t(), String.t(), Entry.key(), term(), Entry.value_type(), keyword()) :: Entry.t()
  defp e(section, label, key, default, type, opts \\ []) do
    %Entry{
      section: section,
      label: label,
      key: key,
      default: default,
      type: type,
      env_var: Keyword.get(opts, :env_var),
      ui_editable?: Keyword.get(opts, :ui_editable?, false),
      restart_required?: Keyword.get(opts, :restart_required?, false),
      secret?: Keyword.get(opts, :secret?, false)
    }
  end

  @spec project_entry(Entry.t()) :: map()
  defp project_entry(%Entry{} = entry) do
    %{
      group: entry.section,
      label: entry.label,
      key: key_string(entry.key),
      value: redact(entry, read_env(entry.key, entry.default)),
      default: redact(entry, entry.default),
      editable: entry.ui_editable?,
      restart_required: entry.restart_required?,
      env_var: entry.env_var,
      secret: secret_entry?(entry)
    }
  end

  @spec redact(Entry.t(), term()) :: term() | String.t()
  defp redact(entry, value) do
    if secret_entry?(entry), do: "***", else: value
  end

  @spec secret_entry?(Entry.t()) :: boolean()
  defp secret_entry?(%Entry{secret?: true}), do: true
  defp secret_entry?(%Entry{section: "Database"}), do: true
  defp secret_entry?(%Entry{}), do: false

  @spec key_string(Entry.key()) :: String.t()
  defp key_string({namespace, subkey}), do: "#{namespace_string(namespace)}.#{Atom.to_string(subkey)}"
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)

  @spec namespace_string(atom() | module()) :: String.t()
  defp namespace_string(module) when is_atom(module) do
    if module?(module) do
      module
      |> Module.split()
      |> Enum.drop_while(&(&1 == "Elixir" or &1 == "Harness"))
      |> Enum.map_join("_", &Macro.underscore/1)
    else
      Atom.to_string(module)
    end
  end

  @spec module?(atom()) :: boolean()
  defp module?(atom), do: atom |> Atom.to_string() |> String.starts_with?("Elixir.")
end
