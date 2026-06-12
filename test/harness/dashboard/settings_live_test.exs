defmodule Harness.Dashboard.SettingsLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for `Harness.Dashboard.SettingsLive` — the
  cron-autonomy controls (Tasks 109/110): master switch, per-project toggle,
  resolved status, and the master-on-but-nothing-enabled warning — plus the
  per-agent enable/disable card (Task 128), the read-only config inspector
  (Task 127), the per-project Landing card, and the Dispatch now button.

  `async: false` — reads the global `ProjectRegistry` and the test settings
  store scope, reset per test.
  """

  # async: false because tests mutate ProjectRegistry, AgentRegistry, settings, and app env.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentRegistry
  alias Harness.Config
  alias Harness.Cron.RoadmapPoller
  alias Harness.Cron.Settings
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ModelAvailability
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.SettingsStore
  alias Harness.Test.SettingsStoreMemory

  setup %{conn: conn} do
    prior_polling = Application.get_env(:harness, :cron_polling)
    prior_run = Application.get_env(:harness, :run)
    prior_dispatch = Application.get_env(:harness, :dispatch)
    prior_agent_model = Application.get_env(:harness, :agent_model)
    prior_reviewer_model = Application.get_env(:harness, :reviewer_model)
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_settings_store = Application.get_env(:harness, :settings_store)
    prior_probe = Application.get_env(:harness, :model_catalog_probe)

    # Keep the model dropdowns from shelling out to real agent CLIs on mount:
    # probeable agents (cursor/grok) resolve to catalog_unavailable, so only the
    # built-in claude/codex seeds render as a <select> and the rest stay text inputs.
    Application.put_env(:harness, :model_catalog_probe, fn _agent, _ -> {:error, :catalog_unavailable} end)

    SettingsStoreMemory.reset(scope: :test_default)
    SettingsStore.put(:model_catalog_static, %{})
    SettingsStore.put(:model_catalogs, %{})

    # Other async:false dashboard tests may leave projects registered; isolate this page.
    for %{name: name} <- ProjectRegistry.list() do
      ProjectRegistry.unregister(name)
    end

    project = ProjectFixture.from_repo("/tmp/harness-settings-live", name: "settings-live")
    :ok = ProjectRegistry.register(project)

    on_exit(fn ->
      ProjectRegistry.unregister(project.name)
      restore_env(:cron_polling, prior_polling)
      restore_env(:run, prior_run)
      restore_env(:dispatch, prior_dispatch)
      restore_env(:agent_model, prior_agent_model)
      restore_env(:reviewer_model, prior_reviewer_model)
      restore_env(:repo_enabled, prior_repo_enabled)
      restore_env(:settings_store, prior_settings_store)
      restore_env(:model_catalog_probe, prior_probe)
      SettingsStoreMemory.reset(scope: :test_default)
    end)

    {:ok, conn: conn, project: project}
  end

  test "renders the settings page with autonomy off by default", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Cron autonomy"
    assert html =~ "polling disabled"
    assert html =~ project.name
    refute html =~ "will NOT survive a restart"
    # The master switch reads as off.
    assert html =~ ~s(role="switch")
    assert html =~ ~s(aria-checked="false")
  end

  test "renders a persistent no-op settings-store banner", %{conn: conn} do
    Application.put_env(:harness, :repo_enabled, false)
    Application.delete_env(:harness, :settings_store)

    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ ~s(data-persistent="true")
    assert html =~ "Settings are ephemeral"
    assert html =~ "will NOT survive a restart"
  end

  test "does not render the ephemeral banner when the settings store persists", %{conn: conn} do
    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: :test_default})

    {:ok, _view, html} = live(conn, "/harness/settings")

    refute html =~ "Settings are ephemeral"
    refute html =~ "will NOT survive a restart"
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

  test "renders the schedule picker with the active preset selected", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ ~s(phx-change="set_schedule")
    assert html =~ "Poll cadence"
    # The default schedule (0 * * * *) is the "hourly" preset, pre-selected.
    assert html =~ ~r/<option value="hourly"\s+selected/
  end

  test "choosing a preset persists the schedule and confirms", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> element("form[phx-change=set_schedule]")
      |> render_change(%{preset: "6h"})

    assert html =~ "Schedule updated"
    assert RoadmapPoller.schedule() == "0 */6 * * *"
    assert Settings.active_preset() == "6h"
  end

  test "an unknown preset is rejected with an error notice", %{conn: conn} do
    before = RoadmapPoller.schedule()
    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> element("form[phx-change=set_schedule]")
      |> render_change(%{preset: "every-minute"})

    assert html =~ "Unknown schedule preset."
    # The rejected value never reached the config.
    assert RoadmapPoller.schedule() == before
  end

  test "renders the Agents card with every adapter enabled by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Agents"
    assert html =~ "Claude"
    assert html =~ "Codex"
    # An enabled agent reads "enabled" and exposes a toggle_agent control.
    assert html =~ "enabled"
    assert html =~ ~s(phx-click="toggle_agent")
  end

  test "toggling an agent disables it for dispatch", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/harness/settings")

    # codex is enabled by default (claude is disabled by the in-code seed), so
    # toggle it to exercise the enabled -> disabled transition.
    html =
      view
      |> element("button[phx-click=toggle_agent][phx-value-name='codex']")
      |> render_click()

    assert html =~ "disabled"
    assert AgentSettings.disabled?(:codex)
    refute AgentSettings.disabled?(:cursor)
  end

  test "toggling reviewer-eligible flips an agent's review-gate eligibility (Task 182)", %{conn: conn} do
    {:ok, view, html} = live(conn, "/harness/settings")

    assert html =~ "reviewer ineligible"
    refute AgentSettings.reviewer_eligible?(:pi)

    html =
      view
      |> element("button[phx-click=toggle_reviewer_eligible][phx-value-name='pi']")
      |> render_click()

    assert html =~ "reviewer eligible"
    assert AgentSettings.reviewer_eligible?(:pi)
    # The independent axis is untouched: Pi stays disabled as an implementer
    # (disabled by the in-code seed; the reviewer toggle does not flip it).
    refute AgentSettings.enabled?(:pi)
  end

  test "a transiently-unavailable agent renders a paused pill (folded in from the dashboard)", %{conn: conn} do
    :ok = AgentRegistry.mark_unavailable(Codex, {:quota_exhausted, :codex})
    on_exit(fn -> AgentRegistry.mark_available(Codex) end)

    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "paused"
    assert html =~ "quota_exhausted"
  end

  test "renders the editable config card with a row per ui-editable key (Task 167)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Run &amp; dashboard config"
    assert html =~ ~s(phx-submit="set_config")
    # A run-timeout row and the restart-required dashboard port row both render.
    assert html =~ ~s(id="config-form-run__lifetime_timeout")
    assert html =~ ~s(id="config-form-dashboard__port")
    # The port carries the restart pill; run timeouts don't.
    assert html =~ "restart"
  end

  test "editing a run timeout persists through Harness.Config and confirms (Task 167)", %{conn: conn} do
    Application.put_env(:harness, :run, lifetime_timeout: 5_400_000)

    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> form("#config-form-run__lifetime_timeout", %{value: "99000"})
      |> render_submit()

    assert html =~ "lifetime_timeout saved."
    assert Config.get({:run, :lifetime_timeout}) == 99_000
  end

  test "a restart-required edit is persisted but not hot-applied, and says so (Task 167)", %{conn: conn} do
    Application.put_env(:harness, :dashboard, port: 4018)

    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> form("#config-form-dashboard__port", %{value: "4099"})
      |> render_submit()

    assert html =~ "applies on the next node restart"
    # Live value unchanged until the next boot.
    assert Config.get({:dashboard, :port}) == 4018
  end

  test "an invalid config value surfaces an error and changes nothing (Task 167)", %{conn: conn} do
    Application.put_env(:harness, :run, lifetime_timeout: 5_400_000)

    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> form("#config-form-run__lifetime_timeout", %{value: "not-a-number"})
      |> render_submit()

    assert html =~ "Unknown or invalid config value."
    assert Config.get({:run, :lifetime_timeout}) == 5_400_000
  end

  test "renders the Dispatch default card seeded with the configured agent (Task 207)", %{conn: conn} do
    Application.put_env(:harness, :dispatch, default_agent: :codex)

    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Dispatch default"
    assert html =~ "Unassigned →"
  end

  test "choosing a dispatch default persists through Harness.Config and confirms (Task 207)", %{conn: conn} do
    Application.put_env(:harness, :dispatch, default_agent: :codex)

    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> form("#dispatch-default-form", %{agent: "cursor"})
      |> render_submit()

    assert html =~ "Default dispatch agent set to cursor."
    assert Config.get({:dispatch, :default_agent}) == :cursor
  end

  test "an unknown dispatch agent is rejected with an error notice (Task 207)", %{conn: conn} do
    Application.put_env(:harness, :dispatch, default_agent: :codex)

    {:ok, view, _html} = live(conn, "/harness/settings")

    # The select only offers valid agents, so push the event directly to exercise
    # the handler's rejection of a crafted out-of-set value.
    html = render_hook(view, "set_default_agent", %{"agent" => "droid"})

    assert html =~ "Unknown dispatch agent."
    assert Config.get({:dispatch, :default_agent}) == :codex
  end

  test "renders and edits reviewer model overrides separately from agent defaults", %{conn: conn} do
    Application.put_env(:harness, :agent_model, cursor: "composer-2.5-fast")

    {:ok, view, html} = live(conn, "/harness/settings")

    assert html =~ "Agent models"
    assert html =~ "Reviewer models"
    assert html =~ "Blank inherits the agent default"
    assert html =~ ~s(id="reviewer-model-reviewer_model__cursor")
    assert html =~ ~s(placeholder="composer-2.5-fast")

    html =
      view
      |> form("#reviewer-model-reviewer_model__cursor", %{value: "claude-opus-4-8-thinking-high"})
      |> render_submit()

    assert html =~ "Cursor reviewer saved."
    assert Config.reviewer_model(:cursor) == "claude-opus-4-8-thinking-high"
  end

  test "adds and removes operator catalog models without a restart", %{conn: conn} do
    {:ok, view, html} = live(conn, "/harness/settings")

    assert html =~ "Model catalog"
    assert html =~ "gpt-5.5"

    html =
      view
      |> form("#model-catalog-add-codex", %{model_id: "gpt-operator-new"})
      |> render_submit()

    assert html =~ "Added gpt-operator-new to codex."
    assert {:ok, models} = ModelAvailability.catalog(:codex)
    assert "gpt-operator-new" in Enum.map(models, & &1.id)
    assert html =~ "gpt-operator-new"

    html =
      view
      |> form("#model-catalog-remove-codex-gpt-operator-new")
      |> render_submit()

    assert html =~ "Removed gpt-operator-new from codex."
    assert {:ok, models} = ModelAvailability.catalog(:codex)
    refute "gpt-operator-new" in Enum.map(models, & &1.id)
    refute has_element?(view, "#model-catalog-remove-codex-gpt-operator-new")
  end

  test "refresh from CLI merges probed models into the editable catalog", %{conn: conn} do
    SettingsStore.put(:model_catalog_static, %{
      cursor: [%{id: "composer-operator", label: "Operator", annotations: []}]
    })

    Application.put_env(:harness, :model_catalog_probe, fn
      :cursor, _executables ->
        {:ok,
         [
           %{id: "composer-operator", label: "Probe duplicate", annotations: []},
           %{id: "composer-probed", label: "Probed", annotations: []}
         ]}

      _agent, _executables ->
        {:error, :catalog_unavailable}
    end)

    {:ok, view, html} = live(conn, "/harness/settings")
    assert html =~ "composer-operator"
    refute html =~ "composer-probed"

    html =
      view
      |> form("#model-catalog-refresh-cursor")
      |> render_submit()

    assert html =~ "Refreshed cursor models."
    assert {:ok, models} = ModelAvailability.catalog(:cursor)
    assert Enum.map(models, & &1.id) == ["composer-operator", "composer-probed"]
    assert html =~ "composer-probed"
  end

  test "renders the Landing card with a per-project policy control", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Landing"
    assert html =~ project.name
    # A project defaults to manual landing, with an auto-land option and a branch input.
    assert html =~ "auto-land"
    assert html =~ ~s(name="target_branch")
    assert html =~ ~s(phx-submit="set_landing")
  end

  test "arming auto-land persists the override and confirms", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> form("#landing-form-#{project.name}", %{landing_policy: "auto", target_branch: "release"})
      |> render_submit()

    assert html =~ "Landing updated for #{project.name}"
    effective = LandingSettings.effective(project)
    assert effective.landing_policy == :auto
    assert effective.target_branch == "release"
  end

  test "arming auto-land without a target branch is rejected", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> form("#landing-form-#{project.name}", %{landing_policy: "auto", target_branch: ""})
      |> render_submit()

    assert html =~ "needs a target branch"
    # The rejected submit never armed the project.
    assert LandingSettings.effective(project).landing_policy == :manual
  end

  test "setting and clearing a per-project reviewer persists the override", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/harness/settings")

    html =
      view
      |> form("#reviewer-form-#{project.name}", %{name: project.name, reviewer: "codex"})
      |> render_submit()

    assert html =~ "Reviewer updated for #{project.name}"
    assert LandingSettings.effective(project).reviewer == :codex

    html =
      view
      |> form("#reviewer-form-#{project.name}", %{name: project.name, reviewer: ""})
      |> render_submit()

    assert html =~ "Reviewer updated for #{project.name}"
    assert LandingSettings.effective(%{project | reviewer: :codex}).reviewer == nil
  end

  test "Dispatch now with master off explains nothing will dispatch", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/harness/settings")

    html = view |> element("button[phx-click=dispatch_now]") |> render_click()

    assert html =~ "Master autonomy is off"
  end

  test "Dispatch now with master on enqueues a poll and confirms", %{conn: conn} do
    Application.put_env(:harness, :oban_insert, fn changeset -> {:ok, changeset} end)
    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)

    {:ok, view, _html} = live(conn, "/harness/settings")
    view |> element("button[phx-click=toggle_master_autonomy]") |> render_click()

    html = view |> element("button[phx-click=dispatch_now]") |> render_click()

    assert html =~ "Poll dispatched"
  end

  test "Dispatch now surfaces an enqueue failure", %{conn: conn} do
    Application.put_env(:harness, :oban_insert, fn _changeset -> {:error, :queue_down} end)
    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)

    {:ok, view, _html} = live(conn, "/harness/settings")
    view |> element("button[phx-click=toggle_master_autonomy]") |> render_click()

    html = view |> element("button[phx-click=dispatch_now]") |> render_click()

    assert html =~ "Could not enqueue a poll"
  end

  test "renders the read-only config inspector card with concern sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "Configuration"
    assert html =~ "Run timeouts"
    assert html =~ "Result store"
    assert html =~ "Registered projects"
  end

  test "the config inspector renders a config.exs-divergent value, not the default", %{conn: conn} do
    prior_run = Application.get_env(:harness, :run)
    Application.put_env(:harness, :run, terminal_linger: 9_000)
    on_exit(fn -> restore_env(:run, prior_run) end)

    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "terminal_linger"
    assert html =~ "9 s (9000 ms)"
  end

  test "the config inspector shows the env-var knob, a humanized duration, and the legend", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/harness/settings")

    # The knob: how to change a value, shown even when it's at its default.
    assert html =~ "HARNESS_DASHBOARD_PORT"
    # Durations are humanized, not raw ms.
    assert html =~ "30 min"
    # The legend explains the provenance vocabulary.
    assert html =~ "built-in default"
  end

  test "the config inspector redacts the dashboard secret", %{conn: conn} do
    secret = Application.get_env(:harness, Harness.Dashboard.Endpoint)[:secret_key_base]

    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "[redacted]"
    refute html =~ secret
  end

  test "the config inspector shows the notification-sinks empty-state", %{conn: conn} do
    prior_sinks = Application.get_env(:harness, :notification_sinks)
    Application.put_env(:harness, :notification_sinks, [])
    on_exit(fn -> restore_env(:notification_sinks, prior_sinks) end)

    {:ok, _view, html} = live(conn, "/harness/settings")

    assert html =~ "none (silent)"
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
