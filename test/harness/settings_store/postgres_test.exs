defmodule Harness.SettingsStore.PostgresTest do
  # async: false because DataCase uses SQL Sandbox shared mode and settings app env.
  use Harness.DataCase, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.Cron.Settings, as: CronSettings
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ProjectFixture
  alias Harness.SettingsStore.Postgres, as: PostgresStore
  alias Harness.SettingsStore.Schema.Setting

  @moduletag :integration

  setup do
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_settings_store = Application.get_env(:harness, :settings_store)

    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :settings_store, {PostgresStore, repo: Repo})

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:settings_store, prior_settings_store)
    end)

    :ok
  end

  test "domain readers return defaults when no settings row exists" do
    project = ProjectFixture.from_repo("/tmp/settings-store-pg", name: "settings-store-pg")

    assert AgentSettings.enabled?(:cursor)
    refute AgentSettings.reviewer_eligible?(:pi)
    refute CronSettings.master_enabled?()
    refute CronSettings.project_enabled?(project)
    assert CronSettings.active_preset() == "hourly"
    assert LandingSettings.effective(project) == %{landing_policy: :manual, target_branch: nil, reviewer: nil}
    assert Repo.aggregate(Setting, :count) == 0
  end

  test "domain setters upsert key-value rows" do
    assert :ok = AgentSettings.set_enabled(:codex, false, "test")
    assert :ok = AgentSettings.set_enabled(:codex, true, "test")

    assert %Setting{key: "agent", payload: payload} = Repo.get(Setting, "agent")
    assert %{disabled: []} = :erlang.binary_to_term(payload)
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
