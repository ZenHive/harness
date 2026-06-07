defmodule Harness.Cron.Settings do
  @moduledoc """
  Persisted, runtime-flippable autonomy switches for cron-driven roadmap polling
  (Tasks 109 + 110).

  Two switches govern unattended dispatch of code-writing agents:

    * the **master** flag — the fleet-wide kill-switch (`master_enabled?/0`),
      which `Harness.Cron.RoadmapPoller.enabled?/0` and `status/0` read;
    * a **per-project** flag — a `%{project_name => boolean()}` map. **Absence
      means OFF**, so a freshly registered project is non-autonomous until an
      operator opts it in.

  Effective autonomy for a project is `master AND project` (`effective?/1`).

  ## Dispatch mode (Task 237) — a third dimension, orthogonal to on/off

  A per-project **dispatch mode** — `:auto` (default) | `:manual`. **Absence
  means `:auto`**, so existing autonomous projects keep auto-dispatching with
  zero behavior change. Mode only matters once a project is `effective?/1`: under
  `:manual` the poller PARKS its resolved dispatch decision for operator approval
  (`Harness.Cron.PendingDispatch`) instead of enqueueing it. `dispatch_mode/1`
  reads it; `set_dispatch_mode/3` flips it.

  ## Schedule (Task 111) — boot-applied, not live

  The cron **schedule** (`schedule/0`) is persisted here too. Unlike the switches
  above it is **boot-applied**: the Oban Cron plugin's crontab is built once at
  startup (`RoadmapPoller.cron_plugin/0`), so a changed schedule takes effect on
  the **next restart**, not the next tick. `set_schedule/2` accepts only a closed
  `schedule_presets/0` whitelist — a free-form crontab can never reach Oban.

  ## One Postgres table, read directly

  All four values live in one record in `Harness.SettingsStore` (Postgres when
  `:repo_enabled`) keyed `:cron`. Every read goes straight to the store — no
  `:cron_polling` app-env cache, no boot loader — so a flip is the single source
  of truth and survives a restart. With `repo_enabled: false` the store is
  ephemeral: master/project default off, dispatch mode `:auto`, schedule the
  in-code default cadence.
  """

  alias Harness.Project
  alias Harness.SettingsStore

  require Logger

  @store_key :cron
  @default_schedule "0 */2 * * *"
  @valid_dispatch_modes [:auto, :manual]

  # The only crontabs that can reach Oban's Cron plugin — a closed
  # `{key, label, crontab}` whitelist. A free-form crontab box would let an
  # invalid expression reach `cron_plugin/0`; a preset picker cannot.
  @schedule_presets [
    {"hourly", "Hourly", "0 * * * *"},
    {"2h", "Every 2 hours", "0 */2 * * *"},
    {"6h", "Every 6 hours", "0 */6 * * *"},
    {"daily", "Daily (midnight)", "0 0 * * *"}
  ]

  @typedoc "A per-project cron dispatch mode."
  @type dispatch_mode :: :auto | :manual

  @typedoc "The persisted settings-store value: both switch sets, dispatch modes, plus the cron schedule."
  @type t :: %{
          optional(:master_enabled) => boolean(),
          optional(:project_autonomy) => %{String.t() => boolean()},
          optional(:dispatch_mode) => %{String.t() => dispatch_mode()},
          optional(:schedule) => String.t()
        }

  @doc "Returns whether the fleet-wide master autonomy switch is on (read from the store)."
  @spec master_enabled?() :: boolean()
  def master_enabled?, do: Map.get(record(), :master_enabled, false) == true

  @doc "Returns whether a project's own autonomy flag is on (absence ⇒ false)."
  @spec project_enabled?(Project.t() | String.t()) :: boolean()
  def project_enabled?(%Project{name: name}), do: project_enabled?(name)
  def project_enabled?(name) when is_binary(name), do: Map.get(project_map(), name, false) == true

  @doc """
  Returns the effective autonomy for a project: `master AND project`. This is the
  truth the poller acts on — the master flag is the single incident kill-switch.
  """
  @spec effective?(Project.t()) :: boolean()
  def effective?(%Project{} = project), do: master_enabled?() and project_enabled?(project)

  @doc """
  Returns a project's cron dispatch mode (`:auto` | `:manual`); absence ⇒ `:auto`.
  """
  @spec dispatch_mode(Project.t() | String.t()) :: dispatch_mode()
  def dispatch_mode(%Project{name: name}), do: dispatch_mode(name)
  def dispatch_mode(name) when is_binary(name), do: Map.get(dispatch_mode_map(), name, :auto)

  @doc """
  Returns the configured cron expression for roadmap polling: the persisted
  schedule when it is a known preset, the default cadence otherwise.
  """
  @spec schedule() :: String.t()
  def schedule do
    case Map.get(record(), :schedule) do
      crontab when is_binary(crontab) ->
        if known_crontab?(crontab), do: crontab, else: default_schedule()

      _unset ->
        default_schedule()
    end
  end

  @doc """
  Flips the master switch at runtime, persists it, and logs an info-level audit
  line naming the actor.
  """
  @spec set_master(boolean(), String.t()) :: :ok
  def set_master(enabled, actor) when is_boolean(enabled) and is_binary(actor) do
    persist(Map.put(record(), :master_enabled, enabled))
    Logger.info("harness cron autonomy: master #{state_word(enabled)} by #{actor}")
    :ok
  end

  @doc """
  Flips a single project's autonomy flag at runtime, persists it, and logs an
  info-level audit line naming the actor.
  """
  @spec set_project(String.t(), boolean(), String.t()) :: :ok
  def set_project(name, enabled, actor) when is_binary(name) and is_boolean(enabled) and is_binary(actor) do
    persist(Map.put(record(), :project_autonomy, Map.put(project_map(), name, enabled)))
    Logger.info("harness cron autonomy: project #{name} #{state_word(enabled)} by #{actor}")
    :ok
  end

  @doc """
  Sets a project's cron dispatch mode at runtime, persists it, and logs an
  info-level audit line naming the actor — mirroring `set_project/3`.

  An invalid mode is rejected (`{:error, :invalid_mode}`) and never written.
  """
  @spec set_dispatch_mode(String.t(), dispatch_mode(), String.t()) :: :ok | {:error, :invalid_mode}
  def set_dispatch_mode(name, mode, actor) when is_binary(name) and mode in @valid_dispatch_modes and is_binary(actor) do
    persist(Map.put(record(), :dispatch_mode, Map.put(dispatch_mode_map(), name, mode)))
    Logger.info("harness cron autonomy: project #{name} dispatch mode #{mode} by #{actor}")
    :ok
  end

  def set_dispatch_mode(name, _mode, actor) when is_binary(name) and is_binary(actor) do
    {:error, :invalid_mode}
  end

  @doc """
  The selectable cron schedules as `{key, label, crontab}` — the closed whitelist
  `set_schedule/2` accepts and the picker renders.
  """
  @spec schedule_presets() :: [{String.t(), String.t(), String.t()}]
  def schedule_presets, do: @schedule_presets

  @doc """
  Returns the preset key of the currently configured schedule, or `nil` when the
  active crontab matches no preset.
  """
  @spec active_preset() :: String.t() | nil
  def active_preset do
    current = schedule()
    Enum.find_value(@schedule_presets, fn {key, _label, crontab} -> if crontab == current, do: key end)
  end

  @doc """
  Sets the cron schedule from a preset key, persists it, and logs an info-level
  audit line naming the actor.

  Only the `schedule_presets/0` keys are accepted; an unknown or free-form key is
  rejected (`{:error, :invalid_preset}`) and never reaches Oban's crontab. The new
  schedule takes effect on the **next BEAM restart** (Task 111).
  """
  @spec set_schedule(String.t(), String.t()) :: :ok | {:error, :invalid_preset}
  def set_schedule(preset_key, actor) when is_binary(preset_key) and is_binary(actor) do
    case Enum.find(@schedule_presets, fn {key, _label, _crontab} -> key == preset_key end) do
      {_key, _label, crontab} ->
        persist(Map.put(record(), :schedule, crontab))
        Logger.info("harness cron autonomy: schedule set to #{crontab} (#{preset_key}) by #{actor}")
        :ok

      nil ->
        {:error, :invalid_preset}
    end
  end

  @spec project_map() :: %{String.t() => boolean()}
  defp project_map do
    case Map.get(record(), :project_autonomy) do
      map when is_map(map) -> map
      _other -> %{}
    end
  end

  @spec dispatch_mode_map() :: %{String.t() => dispatch_mode()}
  defp dispatch_mode_map do
    case Map.get(record(), :dispatch_mode) do
      map when is_map(map) -> sanitize_modes(map)
      _other -> %{}
    end
  end

  @spec sanitize_modes(map()) :: %{String.t() => dispatch_mode()}
  defp sanitize_modes(modes) do
    for {name, mode} <- modes, is_binary(name), mode in @valid_dispatch_modes, into: %{}, do: {name, mode}
  end

  @spec known_crontab?(String.t()) :: boolean()
  defp known_crontab?(crontab), do: Enum.any?(@schedule_presets, fn {_key, _label, ct} -> ct == crontab end)

  # The unflipped cadence is intentionally a code default, not an app-env
  # fallback. Operators change it through the persisted schedule setting.
  @spec default_schedule() :: String.t()
  defp default_schedule, do: @default_schedule

  @spec state_word(boolean()) :: String.t()
  defp state_word(true), do: "enabled"
  defp state_word(false), do: "disabled"

  # The current persisted record, or an empty map (ephemeral store / no row yet).
  # `set_*` preserves the other keys by writing this map back with one replaced.
  @spec record() :: map()
  defp record do
    case SettingsStore.fetch(@store_key) do
      {:ok, map} when is_map(map) -> map
      _missing_or_invalid -> %{}
    end
  end

  @spec persist(t()) :: :ok | {:error, term()}
  defp persist(record), do: SettingsStore.put(@store_key, record)
end
