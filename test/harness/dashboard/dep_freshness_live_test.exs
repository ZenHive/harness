defmodule Harness.Dashboard.DepFreshnessLiveTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.DepFreshness
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
end
