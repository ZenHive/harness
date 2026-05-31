defmodule Harness.Cron.SettingsTest do
  use ExUnit.Case, async: false

  alias Harness.Cron.Settings
  alias Harness.ProjectFixture

  setup do
    prior_settings = Application.get_env(:harness, :cron_settings)
    prior_cron_polling = Application.get_env(:harness, :cron_polling)
    prior_project_autonomy = Application.get_env(:harness, :cron_project_autonomy)

    root = Path.join(System.tmp_dir!(), "harness_cron_settings_#{System.unique_integer([:positive])}")
    Application.put_env(:harness, :cron_settings, root: root)

    on_exit(fn ->
      restore_env(:cron_settings, prior_settings)
      restore_env(:cron_polling, prior_cron_polling)
      restore_env(:cron_project_autonomy, prior_project_autonomy)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "master switch" do
    test "set_master flips app env and persists across a reload" do
      refute Settings.master_enabled?()

      assert :ok = Settings.set_master(true, "test")
      assert Settings.master_enabled?()

      # Simulate a restart: clear env, reload from the persisted file.
      Application.delete_env(:harness, :cron_polling)
      assert :ok = Settings.load_into_env()
      assert Settings.master_enabled?()
    end

    test "set_master preserves the configured schedule" do
      Application.put_env(:harness, :cron_polling, enabled: false, schedule: "* * * * *")

      assert :ok = Settings.set_master(true, "test")

      assert Keyword.get(Application.get_env(:harness, :cron_polling), :schedule) == "* * * * *"
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

    test "project flag persists across a reload" do
      assert :ok = Settings.set_project("proj", true, "test")

      Application.delete_env(:harness, :cron_project_autonomy)
      assert :ok = Settings.load_into_env()
      assert Settings.project_enabled?("proj")
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

  describe "disabled store" do
    test "set_master still flips env but writes nothing" do
      Application.put_env(:harness, :cron_settings, false)

      assert :ok = Settings.set_master(true, "test")
      assert Settings.master_enabled?()

      # Nothing persisted: a reload from the (disabled) store is a no-op, so the
      # env value is whatever was last put, not a file read.
      assert :ok = Settings.load_into_env()
    end

    test "load_into_env is a no-op when no file exists yet", %{root: root} do
      refute File.exists?(Path.join(root, "cron_settings.term"))
      assert :ok = Settings.load_into_env()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
