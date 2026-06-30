defmodule Harness.Dashboard.DepFreshnessLiveTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore
  alias Harness.DepFreshnessStore.Memory, as: Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    prev = Application.get_env(:harness, :dep_freshness_store)
    Application.put_env(:harness, :dep_freshness_store, {Store, scope: :dep_freshness_live_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      Application.put_env(:harness, :dep_freshness_store, prev)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  test "renders stored freshness facts for a project", %{conn: conn} do
    project = ProjectFixture.from_repo("/tmp/harness-deps-live", name: "deps-live")
    :ok = ProjectRegistry.register(project)

    snapshot =
      Snapshot.build("deps-live", "elixir", [
        %Row{
          name: "req",
          current_version: "0.6.1",
          latest_version: "0.6.2",
          constraint_allowed: true
        }
      ])

    assert :ok = DepFreshnessStore.record_snapshot(snapshot, DepFreshnessStore.configured())

    {:ok, _view, html} = live(conn, "/harness/deps/deps-live")

    assert html =~ "Dependency freshness"
    assert html =~ "1 outdated"
    assert html =~ "req"
    assert html =~ "0.6.1"
    assert html =~ "0.6.2"
    assert html =~ "Constraint allowed"
  end

  test "shows empty state before the first scan", %{conn: conn} do
    project = ProjectFixture.from_repo("/tmp/harness-deps-empty", name: "deps-empty")
    :ok = ProjectRegistry.register(project)

    {:ok, _view, html} = live(conn, "/harness/deps/deps-empty")

    assert html =~ "No freshness facts yet"
  end

  test "renders no-project state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/harness/deps")

    assert html =~ "No projects registered."
  end

  test "switches projects from the selector", %{conn: conn} do
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/harness-deps-alpha", name: "deps-alpha"))
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/harness-deps-beta", name: "deps-beta"))

    :ok = DepFreshnessStore.record_snapshot(snapshot("deps-alpha", "alpha_dep"), DepFreshnessStore.configured())
    :ok = DepFreshnessStore.record_snapshot(snapshot("deps-beta", "beta_dep"), DepFreshnessStore.configured())

    {:ok, view, _html} = live(conn, "/harness/deps/deps-alpha")

    html =
      view
      |> element("#dep-freshness-select")
      |> render_change(%{"project" => "deps-beta"})

    assert html =~ "beta_dep"
  end

  test "refreshes snapshots on tick", %{conn: conn} do
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/harness-deps-tick", name: "deps-tick"))

    {:ok, view, html} = live(conn, "/harness/deps/deps-tick")
    assert html =~ "No freshness facts yet"

    :ok = DepFreshnessStore.record_snapshot(snapshot("deps-tick", "tick_dep"), DepFreshnessStore.configured())
    send(view.pid, :deps_tick)

    assert render(view) =~ "tick_dep"
  end

  test "falls back to the first project when the route name is unknown", %{conn: conn} do
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/harness-deps-first", name: "deps-first"))

    {:ok, _view, html} = live(conn, "/harness/deps/missing")

    assert html =~ "deps-first has not been scanned"
  end

  @spec snapshot(String.t(), String.t()) :: Snapshot.t()
  defp snapshot(project_name, dep_name) do
    Snapshot.build(project_name, "elixir", [
      %Row{
        name: dep_name,
        current_version: "0.6.1",
        latest_version: "0.6.2",
        constraint_allowed: false
      }
    ])
  end
end
