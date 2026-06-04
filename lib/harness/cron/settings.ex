defmodule Harness.Cron.Settings do
  @moduledoc """
  Persisted, runtime-flippable autonomy switches for cron-driven roadmap polling
  (Tasks 109 + 110).

  Two switches govern unattended dispatch of code-writing agents:

    * the **master** flag — the fleet-wide kill-switch, stored in the existing
      `:harness, :cron_polling` `:enabled` key so `Harness.Cron.RoadmapPoller`'s
      `enabled?/0` and `status/0` already reflect it;
    * a **per-project** flag — a `%{project_name => boolean()}` map under
      `:harness, :cron_project_autonomy`. **Absence means OFF**, so a freshly
      registered project is non-autonomous until an operator opts it in.

  Effective autonomy for a project is `master AND project` (`effective?/1`).

  ## Schedule (Task 111) — boot-applied, not live

  The cron **schedule** is also persisted here (in the same `:cron_polling` config,
  `:schedule` key, which `RoadmapPoller.schedule/0` already reads). Unlike the
  switches above, it is **boot-applied**: the Oban Cron plugin's crontab is built
  once at startup (`RoadmapPoller.cron_plugin/0`), so a changed schedule takes
  effect on the **next restart**, not the next tick. `set_schedule/2` accepts only
  a closed `schedule_presets/0` whitelist — a free-form crontab can never reach
  Oban. Live runtime reconfig (teardown/re-add of the Cron plugin) is out of scope.

  ## App env is the live cache; SettingsStore is the persistence layer

  `RoadmapPoller.perform/1` already reads `enabled?/0` from app env on every tick,
  so a flip takes effect at the next tick with no restart. This module keeps that
  model: every setter writes app env (the value the poller reads) **and**
  write-throughs to `Harness.SettingsStore` so the choice survives a BEAM
  restart. `load_into_env/0` runs once on boot to seed app env from the shared
  store before Oban starts.

  ## Disabling

  `config :harness, :cron_settings, false` (or `nil`) short-circuits persistence:
  setters still update app env (runtime flips work) but nothing is written, and
  `load_into_env/0` is a no-op. Otherwise the legacy root is used by the file
  fallback and for first-boot import of old `cron_settings.term` files.
  """

  alias Harness.Cron.RoadmapPoller
  alias Harness.Project
  alias Harness.SettingsStore

  require Logger

  @default_root "~/.harness"
  @filename "cron_settings.term"
  @store_key :cron

  # The only crontabs that can reach Oban's Cron plugin — a closed
  # `{key, label, crontab}` whitelist. A free-form crontab box would let an
  # invalid expression reach `cron_plugin/0`; a preset picker cannot. `"2h"` is
  # the `RoadmapPoller` default (`@default_schedule "0 */2 * * *"`).
  @schedule_presets [
    {"hourly", "Hourly", "0 * * * *"},
    {"2h", "Every 2 hours", "0 */2 * * *"},
    {"6h", "Every 6 hours", "0 */6 * * *"},
    {"daily", "Daily (midnight)", "0 0 * * *"}
  ]

  @typedoc "The persisted settings-store value: both switch sets plus the cron schedule."
  @type t :: %{
          required(:master_enabled) => boolean(),
          required(:project_autonomy) => %{String.t() => boolean()},
          optional(:schedule) => String.t()
        }

  @doc """
  Seeds app env from the persisted store. Called once on boot, before Oban starts,
  so `RoadmapPoller.enabled?/0` reflects the persisted master flag from t=0.

  No file (or a disabled store) leaves the compile-time config defaults in place.
  """
  @spec load_into_env() :: :ok
  def load_into_env do
    case SettingsStore.fetch(@store_key, store_opts()) do
      {:ok, record} when is_map(record) -> apply_record(record)
      _missing_or_invalid -> :ok
    end
  end

  # Seeds app env from a persisted record. A record missing `:schedule` (written
  # before Task 111) leaves the default in place; a stored schedule outside the
  # current preset whitelist is ignored, never applied.
  @spec apply_record(map()) :: :ok
  defp apply_record(%{master_enabled: master, project_autonomy: projects} = record)
       when is_boolean(master) and is_map(projects) do
    put_master(master)
    Application.put_env(:harness, :cron_project_autonomy, projects)
    apply_schedule(Map.get(record, :schedule))
    :ok
  end

  defp apply_record(_other), do: :ok

  @spec apply_schedule(term()) :: :ok
  defp apply_schedule(crontab) when is_binary(crontab) do
    if known_crontab?(crontab) do
      put_schedule(crontab)
    else
      Logger.warning(
        "harness cron autonomy: ignoring persisted schedule #{inspect(crontab)} — not in the preset whitelist"
      )
    end

    :ok
  end

  defp apply_schedule(_other), do: :ok

  @doc "Returns whether the fleet-wide master autonomy switch is on."
  @spec master_enabled?() :: boolean()
  def master_enabled? do
    :harness
    |> Application.get_env(:cron_polling, [])
    |> Keyword.get(:enabled, false)
    |> Kernel.==(true)
  end

  @doc "Returns whether a project's own autonomy flag is on (absence ⇒ false)."
  @spec project_enabled?(Project.t() | String.t()) :: boolean()
  def project_enabled?(%Project{name: name}), do: project_enabled?(name)
  def project_enabled?(name) when is_binary(name), do: Map.get(project_map(), name, false)

  @doc """
  Returns the effective autonomy for a project: `master AND project`. This is the
  truth the poller acts on — the master flag is the single incident kill-switch.
  """
  @spec effective?(Project.t()) :: boolean()
  def effective?(%Project{} = project), do: master_enabled?() and project_enabled?(project)

  @doc """
  Flips the master switch at runtime, persists it, and logs an info-level audit
  line naming the actor.
  """
  @spec set_master(boolean(), String.t()) :: :ok
  def set_master(enabled, actor) when is_boolean(enabled) and is_binary(actor) do
    put_master(enabled)
    persist()
    Logger.info("harness cron autonomy: master #{state_word(enabled)} by #{actor}")
    :ok
  end

  @doc """
  Flips a single project's autonomy flag at runtime, persists it, and logs an
  info-level audit line naming the actor.
  """
  @spec set_project(String.t(), boolean(), String.t()) :: :ok
  def set_project(name, enabled, actor) when is_binary(name) and is_boolean(enabled) and is_binary(actor) do
    Application.put_env(:harness, :cron_project_autonomy, Map.put(project_map(), name, enabled))
    persist()
    Logger.info("harness cron autonomy: project #{name} #{state_word(enabled)} by #{actor}")
    :ok
  end

  @doc """
  The selectable cron schedules as `{key, label, crontab}` — the closed whitelist
  `set_schedule/2` accepts and the picker renders.
  """
  @spec schedule_presets() :: [{String.t(), String.t(), String.t()}]
  def schedule_presets, do: @schedule_presets

  @doc """
  Returns the preset key of the currently configured schedule, or `nil` when the
  active crontab matches no preset (e.g. a config-file override outside the set).
  """
  @spec active_preset() :: String.t() | nil
  def active_preset do
    current = RoadmapPoller.schedule()
    Enum.find_value(@schedule_presets, fn {key, _label, crontab} -> if crontab == current, do: key end)
  end

  @doc """
  Sets the cron schedule from a preset key, persists it, and logs an info-level
  audit line naming the actor.

  Only the `schedule_presets/0` keys are accepted; an unknown or free-form key is
  rejected (`{:error, :invalid_preset}`) and never reaches Oban's crontab. The new
  schedule takes effect on the **next BEAM restart** — the Oban Cron plugin's
  crontab is built once at boot (`RoadmapPoller.cron_plugin/0`); live reconfig is
  out of scope (Task 111).
  """
  @spec set_schedule(String.t(), String.t()) :: :ok | {:error, :invalid_preset}
  def set_schedule(preset_key, actor) when is_binary(preset_key) and is_binary(actor) do
    case Enum.find(@schedule_presets, fn {key, _label, _crontab} -> key == preset_key end) do
      {_key, _label, crontab} ->
        put_schedule(crontab)
        persist()
        Logger.info("harness cron autonomy: schedule set to #{crontab} (#{preset_key}) by #{actor}")
        :ok

      nil ->
        {:error, :invalid_preset}
    end
  end

  @spec project_map() :: %{String.t() => boolean()}
  defp project_map, do: Application.get_env(:harness, :cron_project_autonomy, %{})

  @spec known_crontab?(String.t()) :: boolean()
  defp known_crontab?(crontab), do: Enum.any?(@schedule_presets, fn {_key, _label, ct} -> ct == crontab end)

  # Writes the schedule into the existing :cron_polling config, preserving the
  # :enabled flag (and any other keys) so RoadmapPoller's reads are unaffected.
  @spec put_schedule(String.t()) :: :ok
  defp put_schedule(crontab) do
    config = Application.get_env(:harness, :cron_polling, [])
    Application.put_env(:harness, :cron_polling, Keyword.put(config, :schedule, crontab))
  end

  # Writes the master flag into the existing :cron_polling config, preserving the
  # schedule (and any other keys) so RoadmapPoller's reads are unaffected.
  @spec put_master(boolean()) :: :ok
  defp put_master(enabled) do
    config = Application.get_env(:harness, :cron_polling, [])
    Application.put_env(:harness, :cron_polling, Keyword.put(config, :enabled, enabled))
  end

  @spec state_word(boolean()) :: String.t()
  defp state_word(true), do: "enabled"
  defp state_word(false), do: "disabled"

  @spec persist() :: :ok | {:error, term()}
  defp persist do
    SettingsStore.put(@store_key, current_state(), store_opts())
  end

  @spec current_state() :: t()
  defp current_state do
    %{master_enabled: master_enabled?(), project_autonomy: project_map(), schedule: RoadmapPoller.schedule()}
  end

  @spec store_opts() :: SettingsStore.legacy_opts()
  defp store_opts, do: [legacy_config_key: :cron_settings, legacy_filename: @filename, default_root: @default_root]
end
