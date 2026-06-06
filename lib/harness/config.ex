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

  Mirrors the existing settings domains (`Harness.Cron.Settings`,
  `Harness.Agent.Settings`): `get/1` reads the value already folded into app env
  (compile-time default → `config.exs` → `runtime.exs` env var → persisted UI
  override). `put/3` validates against the schema, write-throughs to
  `Harness.SettingsStore`, and — unless the key is `restart_required?` — applies
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

  alias Harness.Config.Entry
  alias Harness.SettingsStore

  require Logger

  @default_root "~/.harness"
  @filename "config_settings.term"
  @store_key :config

  # The implementer agents an unassigned task may default-route to — the closed
  # set the `:agent`-typed `{:dispatch, :default_agent}` key validates against and
  # the dashboard select renders. Mirrors `Harness.Roadmap`'s `@valid_agents`
  # (minus `:human`, which is never an autonomous dispatch target).
  @implementer_agents [:claude, :codex, :cursor, :grok, :antigravity, :pi]

  @doc """
  The full declarative config schema — one `Entry` per operator-relevant key.

  Computed/derived inspector rows (result store, settings store backend) are not
  here: they are `*.configured/0` derivations, not simple keyed config, and stay
  inspector-local. Test-injection seams (`:roadmap_list`, `:run_starter`, …) are
  deliberately absent — they are seams, not operator config.
  """
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
      e("Cron polling", "enabled", {:cron_polling, :enabled}, false, :boolean),
      e("Cron polling", "schedule", {:cron_polling, :schedule}, "0 */2 * * *", :string, restart_required?: true),
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
      e("Database", "database", {Harness.Repo, :database}, nil, :string, env_var: "HARNESS_DB_NAME"),
      e("Database", "username", {Harness.Repo, :username}, nil, :string, env_var: "HARNESS_DB_USER"),
      e("Database", "hostname", {Harness.Repo, :hostname}, nil, :string, env_var: "HARNESS_DB_HOST")
    ]
  end

  @doc "The `ui_editable?` subset of the schema, in declaration order — the editable dashboard card's source."
  @spec editable_entries() :: [Entry.t()]
  def editable_entries, do: Enum.filter(schema(), & &1.ui_editable?)

  @doc "The implementer agents an unassigned task may default-route to — the dashboard select's option source and the `:agent`-type validation set."
  @spec dispatch_agents() :: [atom()]
  def dispatch_agents, do: @implementer_agents

  @doc """
  Resolves a schema key's effective value from app env, falling back to the
  schema default. Raises on an unknown key (a typo is a programming error, not a
  runtime condition). This is the read path code uses instead of a raw
  `Application.get_env/3` for schema-covered keys.
  """
  @spec get(Entry.key()) :: term()
  def get(key) do
    case fetch_entry(key) do
      {:ok, entry} -> read_env(entry.key, entry.default)
      :error -> raise ArgumentError, "unknown config key: #{inspect(key)}"
    end
  end

  @doc """
  Sets a `ui_editable?` key at runtime: validates the value against the entry's
  type, persists it as an override, applies it to app env live (unless the key is
  `restart_required?`), and logs an audit line naming the actor.

  Returns `{:error, :unknown_key | :not_editable | :invalid_value}` without
  mutating anything on a bad request.
  """
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

  @doc """
  Seeds app env from persisted overrides. Called once on boot, before the runtime
  reads any schema-covered key. A key whose `env_var` is set is skipped (the env
  var wins); an override for a key no longer in the schema is ignored.
  """
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
    SettingsStore.put(@store_key, Map.put(overrides(), key, value), store_opts())
  end

  @spec overrides() :: %{Entry.key() => term()}
  defp overrides do
    case SettingsStore.fetch(@store_key, store_opts()) do
      {:ok, map} when is_map(map) -> map
      _missing_or_invalid -> %{}
    end
  end

  @spec store_opts() :: SettingsStore.legacy_opts()
  defp store_opts, do: [legacy_config_key: :config_settings, legacy_filename: @filename, default_root: @default_root]

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
end
