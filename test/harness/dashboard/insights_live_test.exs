defmodule Harness.Dashboard.InsightsLiveTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Insights
  alias Harness.Insights.Evidence
  alias Harness.Insights.Publication
  alias Harness.Insights.Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Test.InsightsWitness

  setup do
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
      "agent" => "claude",
      "model" => "sonnet"
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
      Publication.prepare(%{"findings" => [finding]}, [source], [], "ui-pass", %{"agent" => "claude", "model" => "sonnet"})

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
end
