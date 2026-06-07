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

    root = Path.join(System.tmp_dir!(), "harness_settings_store_pg_#{System.unique_integer([:positive])}")

    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :settings_store, {PostgresStore, repo: Repo, legacy_root: root})

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:settings_store, prior_settings_store)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "imports existing legacy term files into Postgres on the first read", %{root: root} do
    project = ProjectFixture.from_repo("/tmp/settings-store-pg", name: "settings-store-pg")
    File.mkdir_p!(root)

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

    # First read of each key imports the legacy file into Postgres and persists it.
    refute AgentSettings.enabled?(:cursor)
    refute AgentSettings.reviewer_eligible?(:pi)
    assert CronSettings.master_enabled?()
    assert CronSettings.project_enabled?(project)
    assert CronSettings.active_preset() == "hourly"
    assert LandingSettings.effective(project) == %{landing_policy: :auto, target_branch: "release", reviewer: nil}
    assert Repo.aggregate(Setting, :count) == 3

    # Postgres now wins: rewriting the legacy file has no effect after the import.
    assert :ok = TermCodec.write_file(Path.join(root, "agent_settings.term"), %{disabled: [:claude]})

    refute AgentSettings.enabled?(:cursor)
    assert AgentSettings.enabled?(:claude)
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
