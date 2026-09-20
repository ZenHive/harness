defmodule Harness.Dashboard.MaintenanceLiveTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Maintenance
  alias Harness.Maintenance.Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    Store.get("init")
    :ets.delete_all_objects(Store)
    ProjectRegistry.reset()
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/maintenance-ui", name: "maintenance-ui"))

    on_exit(fn ->
      ProjectRegistry.reset()
      :ets.delete_all_objects(Store)
    end)

    :ok
  end

  test "fleet navigation, disabled controls and per-repository settings", %{conn: conn} do
    {:ok, fleet, html} = live(conn, "/harness/maintenance")
    assert html =~ "Maintenance"
    assert html =~ "Ephemeral"
    assert has_element?(fleet, "a", "maintenance-ui")
    {:ok, view, _} = live(conn, "/harness/maintenance/repositories/maintenance-ui")
    assert has_element?(view, "button[phx-click=sweep][disabled]")

    view
    |> form("#maintenance-settings", %{
      "enabled" => "true",
      "cadence_minutes" => "10080",
      "agent" => "codex",
      "model" => "gpt-6-astra",
      "deadline_seconds" => "1800"
    })
    |> render_submit()

    assert Maintenance.settings("maintenance-ui")["enabled"]
    assert render(fleet) =~ "ready"
    refute has_element?(view, "button[phx-click=sweep][disabled]")
    view |> element("button[phx-click=sweep]") |> render_click()
    assert render(view) =~ "ephemeral_scheduler_unavailable"
    view |> form("#maintenance-settings", %{"cadence_minutes" => "0"}) |> render_submit()
    assert render(view) =~ "Settings not saved"
  end

  test "finding history and missing records render without claiming verified improvement", %{conn: conn} do
    f = %{
      "id" => "finding-ui",
      "project" => "maintenance-ui",
      "title" => "Measured improvement",
      "category" => "performance",
      "evidence" => "Before 40ms; after not measured",
      "rationale" => "Comparable benchmark required",
      "improvement" => "Reduce redundant work",
      "outcome" => "Unverified",
      "at" => "2026-09-20",
      "agent" => "codex",
      "model" => "gpt-6-astra",
      "source_revision" => "abc",
      "blocked" => false
    }

    :ok =
      Store.put_many([
        {"finding/finding-ui", "finding/maintenance-ui", f},
        {"revision/finding-ui/1", "revision/finding-ui", f}
      ])

    {:ok, _, html} = live(conn, "/harness/maintenance/findings/finding-ui")
    assert html =~ "Before 40ms"
    assert html =~ "Unverified"
    assert html =~ "Not published"
    {:ok, _, html} = live(conn, "/harness/maintenance/findings/missing")
    assert html =~ "Finding not found"
    {:ok, _, html} = live(conn, "/harness/maintenance/repositories/missing")
    assert html =~ "Repository not found"
  end
end
