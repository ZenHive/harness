defmodule Harness.Dashboard.SettingsLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for `Harness.Dashboard.SettingsLive` — the
  cron-autonomy controls (Tasks 109/110): master switch, per-project toggle,
  resolved status, and the master-on-but-nothing-enabled warning.

  `async: false` — reads the global `ProjectRegistry` and mutates the
  `:cron_polling` / `:cron_project_autonomy` app env, which would leak across
  parallel tests.
  """

  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.Cron.Settings
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup %{conn: conn} do
    prior_polling = Application.get_env(:harness, :cron_polling)
    prior_projects = Application.get_env(:harness, :cron_project_autonomy)
    prior_agents = Application.get_env(:harness, :agent_disabled)

    project = ProjectFixture.from_repo("/tmp/harness-settings-live", name: "settings-live")
    :ok = ProjectRegistry.register(project)

    on_exit(fn ->
      ProjectRegistry.unregister(project.name)
      restore_env(:cron_polling, prior_polling)
      restore_env(:cron_project_autonomy, prior_projects)
      restore_env(:agent_disabled, prior_agents)
    end)

    {:ok, conn: conn, project: project}
  end

  test "renders the settings page with autonomy off by default", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Cron autonomy"
    assert html =~ "polling disabled"
    assert html =~ project.name
    # The master switch reads as off.
    assert html =~ ~s(role="switch")
    assert html =~ ~s(aria-checked="false")
  end

  test "toggling master flips status and warns when no project is enabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> element("button[phx-click=toggle_master_autonomy]")
      |> render_click()

    assert html =~ "Master is on but no project is enabled"
    assert html =~ "scheduled"
    assert html =~ ~s(aria-checked="true")
    assert Settings.master_enabled?()
  end

  test "enabling master then a project clears the warning and makes it effective", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, "/harness/settings")

    view |> element("button[phx-click=toggle_master_autonomy]") |> render_click()

    html =
      view
      |> element("button[phx-value-name='#{project.name}']")
      |> render_click()

    refute html =~ "no project is enabled"
    assert html =~ "dispatching"
    assert Settings.effective?(project)
  end

  test "the navbar exposes a Settings link", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ ~s(href="/harness/settings")
  end

  test "renders the Agents card with every adapter enabled by default", %{conn: conn} do
    Application.put_env(:harness, :agent_disabled, [])

    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Agents"
    assert html =~ "Claude"
    assert html =~ "Codex"
    # An enabled agent reads "enabled" and exposes a toggle_agent control.
    assert html =~ "enabled"
    assert html =~ ~s(phx-click="toggle_agent")
  end

  test "toggling an agent disables it for dispatch", %{conn: conn} do
    Application.put_env(:harness, :agent_disabled, [])

    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> element("button[phx-click=toggle_agent][phx-value-name='claude']")
      |> render_click()

    assert html =~ "disabled"
    assert AgentSettings.disabled?(:claude)
    refute AgentSettings.disabled?(:codex)
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
