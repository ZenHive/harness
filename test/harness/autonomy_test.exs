defmodule Harness.AutonomyTest do
  # async: false because tests reset the singleton ProjectRegistry.
  use ExUnit.Case, async: false

  alias Harness.Autonomy
  alias Harness.Cron.Settings
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Test.SettingsStoreMemory

  @scope :test_default

  setup do
    ProjectRegistry.reset()
    SettingsStoreMemory.reset(scope: @scope)

    on_exit(fn ->
      ProjectRegistry.reset()
      SettingsStoreMemory.reset(scope: @scope)
    end)

    :ok
  end

  test "status/0 returns fleet and per-project autonomy facts" do
    project = ProjectFixture.from_repo("/tmp/harness-autonomy", name: "auto-proj")

    assert :ok = ProjectRegistry.register(project)
    assert :ok = Settings.set_master(true, "test")
    assert :ok = Settings.set_project("auto-proj", true, "test")
    assert :ok = Settings.set_dispatch_mode("auto-proj", :manual, "test")
    assert :ok = Settings.set_schedule("hourly", "test")

    assert %{
             master_enabled: true,
             schedule: "0 * * * *",
             active_preset: "hourly",
             schedule_presets: [%{key: "hourly", label: "Hourly", crontab: "0 * * * *"} | _],
             projects: [
               %{
                 name: "auto-proj",
                 enabled: true,
                 dispatch_mode: "manual",
                 effective: true
               }
             ]
           } = Autonomy.status()
  end
end
