defmodule Harness.SettingsStore.PostgresTest do
  use Harness.DataCase, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.Cron.Settings, as: CronSettings
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ProjectFixture
  alias Harness.SettingsStore.Postgres, as: PostgresStore
  alias Harness.SettingsStore.Schema.Setting
  alias Harness.TermCodec

  @moduletag :integration

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

    root = Path.join(System.tmp_dir!(), "harness_settings_store_pg_#{System.unique_integer([:positive])}")

    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :settings_store, {PostgresStore, repo: Repo})
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

  test "imports existing legacy term files into Postgres on first load", %{root: root} do
    project = ProjectFixture.from_repo("/tmp/settings-store-pg", name: "settings-store-pg")

    assert :ok =
             TermCodec.write_file(Path.join(root, "agent_settings.term"), %{
               disabled: [:cursor],
               reviewer_ineligible: [:pi]
             })

    assert :ok =
             TermCodec.write_file(Path.join(root, "cron_settings.term"), %{
               master_enabled: true,
               project_autonomy: %{project.name => true},
               schedule: "0 * * * *"
             })

    assert :ok =
             TermCodec.write_file(Path.join(root, "landing_settings.term"), %{
               project.name => %{landing_policy: :auto, target_branch: "release"}
             })

    assert :ok = AgentSettings.load_into_env()
    assert :ok = CronSettings.load_into_env()
    assert :ok = LandingSettings.load_into_env()

    refute AgentSettings.enabled?(:cursor)
    refute AgentSettings.reviewer_eligible?(:pi)
    assert CronSettings.master_enabled?()
    assert CronSettings.project_enabled?(project)
    assert CronSettings.active_preset() == "hourly"
    assert LandingSettings.effective(project) == %{landing_policy: :auto, target_branch: "release", reviewer: nil}
    assert Repo.aggregate(Setting, :count) == 3

    assert :ok = TermCodec.write_file(Path.join(root, "agent_settings.term"), %{disabled: [:claude]})
    Application.put_env(:harness, :agent_disabled, [])
    Application.put_env(:harness, :agent_reviewer_ineligible, [])

    assert :ok = AgentSettings.load_into_env()

    refute AgentSettings.enabled?(:cursor)
    assert AgentSettings.enabled?(:claude)
    refute AgentSettings.reviewer_eligible?(:pi)
  end

  test "domain setters upsert key-value rows" do
    assert :ok = AgentSettings.set_enabled(:codex, false, "test")
    assert :ok = AgentSettings.set_enabled(:codex, true, "test")

    assert %Setting{key: "agent", payload: payload} = Repo.get(Setting, "agent")
    assert {:ok, %{disabled: []}} = TermCodec.safe_binary_to_term(payload)
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
