defmodule Harness.Cron.SettingsTest do
  @moduledoc """
  Unit coverage for `Harness.Cron.Settings` — the master/per-project autonomy
  switches, dispatch mode, and cron schedule, all read from and written to the
  one Postgres settings store (the in-memory test backend stands in for Postgres).

  `async: false` — shares the global test settings store scope, reset per test.
  """

  # async: false because tests reset the shared in-memory settings store scope.
  use ExUnit.Case, async: false

  alias Harness.Cron.RoadmapPoller
  alias Harness.Cron.Settings
  alias Harness.ProjectFixture
  alias Harness.SettingsStore
  alias Harness.Test.SettingsStoreMemory
  alias Oban.Cron

  @scope :test_default

  setup do
    SettingsStoreMemory.reset(scope: @scope)
    on_exit(fn -> SettingsStoreMemory.reset(scope: @scope) end)
    :ok
  end

  describe "master switch" do
    test "set_master flips and the choice survives a restart" do
      refute Settings.master_enabled?()

      assert :ok = Settings.set_master(true, "test")
      assert Settings.master_enabled?()

      # No app-env cache: a fresh read (restarted node) still sees the flip.
      assert Settings.master_enabled?()
      assert RoadmapPoller.enabled?()
    end

    test "set_master preserves a stored schedule" do
      assert :ok = Settings.set_schedule("hourly", "test")
      assert :ok = Settings.set_master(true, "test")

      assert Settings.master_enabled?()
      assert Settings.schedule() == "0 * * * *"
    end
  end

  describe "per-project switch" do
    test "project flag defaults off and flips on" do
      project = ProjectFixture.from_repo("/tmp/harness-settings-proj", name: "proj")

      refute Settings.project_enabled?(project)

      assert :ok = Settings.set_project("proj", true, "test")
      assert Settings.project_enabled?("proj")
      assert Settings.project_enabled?(project)
    end

    test "project flag survives a restart" do
      assert :ok = Settings.set_project("proj", true, "test")
      assert Settings.project_enabled?("proj")
    end
  end

  describe "dispatch mode (Task 237)" do
    test "absence defaults to :auto for every project" do
      project = ProjectFixture.from_repo("/tmp/harness-mode-default", name: "mode-default")

      assert Settings.dispatch_mode("mode-default") == :auto
      assert Settings.dispatch_mode(project) == :auto
    end

    test "set_dispatch_mode flips the mode and survives a restart" do
      assert :ok = Settings.set_dispatch_mode("proj", :manual, "test")
      assert Settings.dispatch_mode("proj") == :manual

      # Flipping back to :auto round-trips too.
      assert :ok = Settings.set_dispatch_mode("proj", :auto, "test")
      assert Settings.dispatch_mode("proj") == :auto
    end

    test "set_dispatch_mode is independent of the on/off autonomy flag" do
      assert :ok = Settings.set_project("proj", true, "test")
      assert :ok = Settings.set_dispatch_mode("proj", :manual, "test")

      assert Settings.project_enabled?("proj")
      assert Settings.dispatch_mode("proj") == :manual

      # Clearing autonomy leaves the mode untouched (orthogonal dimensions).
      assert :ok = Settings.set_project("proj", false, "test")
      assert Settings.dispatch_mode("proj") == :manual
    end

    test "an invalid mode is rejected and never written" do
      assert {:error, :invalid_mode} = Settings.set_dispatch_mode("proj", :bogus, "test")
      assert Settings.dispatch_mode("proj") == :auto
    end
  end

  describe "effective?/1" do
    setup do
      project = ProjectFixture.from_repo("/tmp/harness-settings-eff", name: "eff")
      {:ok, project: project}
    end

    test "is true only when master AND project are both on", %{project: project} do
      assert :ok = Settings.set_master(false, "test")
      assert :ok = Settings.set_project("eff", false, "test")
      refute Settings.effective?(project)

      assert :ok = Settings.set_master(true, "test")
      refute Settings.effective?(project)

      assert :ok = Settings.set_project("eff", true, "test")
      assert Settings.effective?(project)

      assert :ok = Settings.set_master(false, "test")
      refute Settings.effective?(project)
    end
  end

  describe "schedule (Task 111)" do
    test "set_schedule round-trips through the store and survives a restart" do
      assert :ok = Settings.set_schedule("6h", "test")
      assert RoadmapPoller.schedule() == "0 */6 * * *"

      # A fresh read (restarted node) still sees the stored schedule.
      assert RoadmapPoller.schedule() == "0 */6 * * *"
      assert Settings.active_preset() == "6h"
    end

    test "cron_plugin/0 reflects the stored schedule" do
      assert :ok = Settings.set_schedule("daily", "test")

      assert {Cron, crontab: [{"0 0 * * *", RoadmapPoller, _opts}]} = RoadmapPoller.cron_plugin()
    end

    test "an unknown preset is rejected and never reaches the store" do
      before = RoadmapPoller.schedule()

      assert {:error, :invalid_preset} = Settings.set_schedule("* * * * *", "test")
      assert {:error, :invalid_preset} = Settings.set_schedule("hourly-ish", "test")

      # The rejected value never persisted, so the schedule is unchanged.
      assert RoadmapPoller.schedule() == before
    end

    test "set_schedule preserves the master flag" do
      assert :ok = Settings.set_master(true, "test")
      assert :ok = Settings.set_schedule("hourly", "test")

      assert Settings.master_enabled?()
      assert RoadmapPoller.schedule() == "0 * * * *"
    end

    test "a persisted schedule outside the preset whitelist is ignored" do
      # An old/hand-edited record could carry a crontab no longer in the whitelist.
      assert :ok =
               SettingsStore.put(:cron, %{master_enabled: false, project_autonomy: %{}, schedule: "*/7 * * * *"})

      # The non-whitelisted crontab is not surfaced; the default stands.
      assert RoadmapPoller.schedule() == "0 * * * *"
    end
  end

  describe "ephemeral store" do
    test "with repo disabled, a flip is a no-op and reads stay at the default" do
      prior = Application.get_env(:harness, :settings_store)
      Application.put_env(:harness, :settings_store, false)
      on_exit(fn -> restore(:settings_store, prior) end)

      assert :ok = Settings.set_master(true, "test")
      # The no-op store discards the write; the read falls back to the default.
      refute Settings.master_enabled?()
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
