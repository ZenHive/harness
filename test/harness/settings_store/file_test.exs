defmodule Harness.SettingsStore.FileTest do
  use ExUnit.Case, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.Cron.Settings, as: CronSettings
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ProjectFixture
  alias Harness.TermCodec

  setup do
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_settings_store = Application.get_env(:harness, :settings_store)
    prior_agent_settings = Application.get_env(:harness, :agent_settings)
    prior_cron_settings = Application.get_env(:harness, :cron_settings)
    prior_landing_settings = Application.get_env(:harness, :landing_settings)
    prior_agent_disabled = Application.get_env(:harness, :agent_disabled)
    prior_reviewer_ineligible = Application.get_env(:harness, :agent_reviewer_ineligible)
    prior_cron_polling = Application.get_env(:harness, :cron_polling)
    prior_cron_project_autonomy = Application.get_env(:harness, :cron_project_autonomy)
    prior_landing_overrides = Application.get_env(:harness, :landing_overrides)

    root = Path.join(System.tmp_dir!(), "harness_settings_store_file_#{System.unique_integer([:positive])}")

    Application.put_env(:harness, :repo_enabled, false)
    Application.delete_env(:harness, :settings_store)
    Application.put_env(:harness, :agent_settings, root: root)
    Application.put_env(:harness, :cron_settings, root: root)
    Application.put_env(:harness, :landing_settings, root: root)
    Application.put_env(:harness, :agent_disabled, [])
    Application.delete_env(:harness, :agent_reviewer_ineligible)
    Application.put_env(:harness, :cron_polling, enabled: false, schedule: "0 */2 * * *")
    Application.put_env(:harness, :cron_project_autonomy, %{})
    Application.put_env(:harness, :landing_overrides, %{})

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:settings_store, prior_settings_store)
      restore(:agent_settings, prior_agent_settings)
      restore(:cron_settings, prior_cron_settings)
      restore(:landing_settings, prior_landing_settings)
      restore(:agent_disabled, prior_agent_disabled)
      restore(:agent_reviewer_ineligible, prior_reviewer_ineligible)
      restore(:cron_polling, prior_cron_polling)
      restore(:cron_project_autonomy, prior_cron_project_autonomy)
      restore(:landing_overrides, prior_landing_overrides)
    end)

    {:ok, root: root}
  end

  test "domain APIs write through one file-backed settings store", %{root: root} do
    project = ProjectFixture.from_repo("/tmp/settings-store-file", name: "settings-store-file")

    assert :ok = AgentSettings.set_enabled(:codex, false, "test")
    assert :ok = CronSettings.set_master(true, "test")
    assert :ok = CronSettings.set_project(project.name, true, "test")
    assert :ok = LandingSettings.set(project.name, :auto, "main", "test")

    assert File.exists?(Path.join(root, "harness_settings.term"))

    Application.put_env(:harness, :agent_disabled, [])
    Application.put_env(:harness, :cron_polling, enabled: false, schedule: "0 */2 * * *")
    Application.put_env(:harness, :cron_project_autonomy, %{})
    Application.put_env(:harness, :landing_overrides, %{})

    assert :ok = AgentSettings.load_into_env()
    assert :ok = CronSettings.load_into_env()
    assert :ok = LandingSettings.load_into_env()

    refute AgentSettings.enabled?(:codex)
    assert CronSettings.master_enabled?()
    assert CronSettings.project_enabled?(project)
    assert LandingSettings.effective(project) == %{landing_policy: :auto, target_branch: "main"}
  end

  test "file backend imports legacy per-domain term files once", %{root: root} do
    assert :ok =
             TermCodec.write_file(Path.join(root, "agent_settings.term"), %{
               disabled: [:grok],
               reviewer_ineligible: [:pi]
             })

    assert :ok = AgentSettings.load_into_env()

    refute AgentSettings.enabled?(:grok)
    refute AgentSettings.reviewer_eligible?(:pi)
    assert File.exists?(Path.join(root, "harness_settings.term"))

    assert :ok =
             TermCodec.write_file(Path.join(root, "agent_settings.term"), %{
               disabled: [:claude],
               reviewer_ineligible: []
             })

    Application.put_env(:harness, :agent_disabled, [])
    Application.put_env(:harness, :agent_reviewer_ineligible, [])

    assert :ok = AgentSettings.load_into_env()

    refute AgentSettings.enabled?(:grok)
    assert AgentSettings.enabled?(:claude)
    refute AgentSettings.reviewer_eligible?(:pi)
  end

  test "legacy per-domain false still disables persistence", %{root: root} do
    Application.put_env(:harness, :agent_settings, false)

    assert :ok = AgentSettings.set_enabled(:codex, false, "test")
    refute AgentSettings.enabled?(:codex)
    refute File.exists?(Path.join(root, "harness_settings.term"))

    Application.put_env(:harness, :agent_disabled, [])
    assert :ok = AgentSettings.load_into_env()
    assert AgentSettings.enabled?(:codex)
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
