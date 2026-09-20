defmodule Harness.Dashboard.InsightsLiveTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Agent.Settings
  alias Harness.Insights
  alias Harness.Insights.Evidence
  alias Harness.Insights.Publication
  alias Harness.Insights.Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.SettingsStore
  alias Harness.Test.InsightsWitness

  setup do
    old_models = Application.get_env(:harness, :agent_model)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")

    on_exit(fn ->
      if old_models,
        do: Application.put_env(:harness, :agent_model, old_models),
        else: Application.delete_env(:harness, :agent_model)
    end)

    Store.get("settings")
    :ets.delete_all_objects(Store)
    ProjectRegistry.reset()
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/insights-ui", name: "insights-ui"))

    on_exit(fn ->
      :ets.delete_all_objects(Store)
      ProjectRegistry.reset()
    end)

    :ok
  end

  test "navbar, disabled empty state and independent settings update live", %{conn: conn} do
    {:ok, view, html} = live(conn, "/harness/insights")
    assert html =~ "AI observations across runs"
    assert html =~ "Ephemeral"
    assert html =~ "Paused — observation is disabled"
    assert has_element?(view, "button[phx-click=observe][disabled]")
    assert html =~ ~s(href="/harness/insights")
    {:ok, settings, _html} = live(conn, "/harness/insights/settings")

    settings
    |> form("#insights-settings", %{
      "enabled" => "true",
      "cadence_minutes" => "15",
      "agent" => "codex",
      "model" => "gpt-6-astra"
    })
    |> render_submit()

    assert Insights.settings()["enabled"]
    assert Insights.settings()["cadence_minutes"] == 15
    assert render(view) =~ "Ready to observe"
    assert render(settings) =~ "Observer settings saved"
  end

  test "project filtering, evidence navigation, revisions and escaped text", %{conn: conn} do
    source = Evidence.source("ui-run", "insights-ui", "reviewer_output", "<script>untrusted evidence</script>", true)
    finding = InsightsWitness.finding(source)

    {:ok, documents} =
      Publication.prepare(%{"findings" => [finding]}, [source], [], "ui-pass", %{
        "agent" => "codex",
        "model" => "gpt-6-astra"
      })

    :ok = Store.put_many(documents)
    [stored] = Insights.findings()["items"]
    {:ok, view, html} = live(conn, "/harness/insights?project=insights-ui")
    assert html =~ "Repeated reviewer repairs"
    view |> form("#insights-filter", %{"project" => ""}) |> render_change()
    assert_patch(view, "/harness/insights?project=")
    {:ok, detail, html} = live(conn, "/harness/insights/" <> stored["id"])
    assert html =~ "AI hypothesis"
    assert html =~ "Provisional"
    assert html =~ "&lt;script&gt;"
    assert has_element?(detail, ~s(a[href="/harness/runs/ui-run"]))
    {:ok, _view, missing} = live(conn, "/harness/insights/unknown")
    assert missing =~ "Finding not found"
    {:ok, _run, run_html} = live(conn, "/harness/runs/ui-run")
    assert run_html =~ "Related Run Insights"
    assert run_html =~ ~s(href="/harness/insights?run_id=ui-run")
    {:ok, _related, related} = live(conn, "/harness/insights?run_id=ui-run")
    assert related =~ "Findings related to run ui-run"
    assert related =~ "Repeated reviewer repairs"
  end

  test "failure and partial status receive broadcasts", %{conn: conn} do
    Insights.configure(Map.put(Insights.settings(), "enabled", true))
    {:ok, view, _} = live(conn, "/harness/insights")
    :ok = Store.put_many([{"pass/ui-fail", "pass", %{"state" => "failed", "error" => "Provider unavailable"}}])
    send(view.pid, :insights_updated)
    assert render(view) =~ "Observation failed"
    assert render(view) =~ "Provider unavailable"
    :ok = Store.put_many([{"pass/ui-partial", "pass", %{"state" => "partial"}}])
    send(view.pid, :insights_updated)
    assert render(view) =~ "Partial evidence"
  end

  test "observing and successful empty states remain distinct", %{conn: conn} do
    Insights.configure(Map.put(Insights.settings(), "enabled", true))
    {:ok, view, _} = live(conn, "/harness/insights")

    for {state, text} <- [
          {"observing", "Observing"},
          {"no_new_evidence", "No new evidence"},
          {"no_findings", "Successful pass — no findings"},
          {"successful", "Observation complete"}
        ] do
      :ok = Store.put_many([{"pass/ui-states", "pass", %{"state" => state}}])
      send(view.pid, :insights_updated)
      assert render(view) =~ text
    end
  end

  test "failed selections preserve settings and render useful errors", %{conn: conn} do
    {:ok, view, _} = live(conn, "/harness/insights/settings")
    prior = Insights.settings()
    params = %{"enabled" => "true", "cadence_minutes" => "60", "agent" => "codex", "model" => "unavailable-model"}
    assert render_submit(view, "save", params) =~ "selected model is unavailable"
    assert Insights.settings() == prior
    assert has_element?(view, "#insights-model option[selected]", "unavailable-model — unavailable")
    assert render_submit(view, "save", Map.put(params, "cadence_minutes", "invalid")) =~ "cadence fields"
    assert render_submit(view, "save", Map.put(params, "agent", "cursor")) =~ "Choose Codex or Claude"
  end

  test "agent changes require a model choice and disabled observers cannot enqueue", %{conn: conn} do
    saved = SettingsStore.fetch_map(:agent)
    on_exit(fn -> SettingsStore.put(:agent, saved) end)
    :ok = Settings.set_enabled(:claude, true, "test")
    {:ok, view, _} = live(conn, "/harness/insights/settings")
    params = %{"enabled" => "false", "cadence_minutes" => "60", "agent" => "claude", "model" => "gpt-6-astra"}
    render_change(view, "change_settings", params)
    assert has_element?(view, "#insights-model option[value=''][selected]")
    assert has_element?(view, "#insights-model option", "claude-")
    assert render_submit(view, "save", Map.put(params, "model", "")) =~ "Select an available model"
    {:ok, overview, _} = live(conn, "/harness/insights")
    assert render_click(overview, "observe") =~ "Observation unavailable: disabled"
    {:ok, filtered, html} = live(conn, "/harness/insights?run_id=missing")
    assert html =~ "No findings match this view"
    assert has_element?(filtered, "a", "Clear filters")
  end
end
