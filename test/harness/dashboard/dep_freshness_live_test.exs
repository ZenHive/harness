defmodule Harness.Dashboard.DepFreshnessLiveTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore
  alias Harness.DepFreshnessStore.Memory, as: Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ToolingBaseline.Advisory
  alias Harness.ToolingBaseline.Item
  alias Harness.ToolingBaseline.Snapshot, as: ConformanceSnapshot

  setup do
    prev = Application.get_env(:harness, :dep_freshness_store)
    prev_creator = Application.get_env(:harness, :dependency_bump_task_creator)
    prev_enqueuer = Application.get_env(:harness, :dependency_bump_enqueuer)
    prev_ingest = Application.get_env(:harness, :roadmap_ingest)

    Application.put_env(:harness, :dep_freshness_store, {Store, scope: :dep_freshness_live_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      Application.put_env(:harness, :dep_freshness_store, prev)
      restore_env(:dependency_bump_task_creator, prev_creator)
      restore_env(:dependency_bump_enqueuer, prev_enqueuer)
      restore_env(:roadmap_ingest, prev_ingest)

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

    assert html =~ "Dependencies &amp; tooling"
    assert html =~ "1 outdated"
    assert html =~ "req"
    assert html =~ "0.6.1"
    assert html =~ "0.6.2"
    assert html =~ "Constraint allowed"
    assert html =~ "Update deps"
  end

  test "dispatches dependency bump runs from the update button", %{conn: conn} do
    owner = self()
    project = ProjectFixture.from_repo("/tmp/harness-deps-update", name: "deps-update")
    :ok = ProjectRegistry.register(project)
    :ok = DepFreshnessStore.record_snapshot(snapshot("deps-update", "req"), DepFreshnessStore.configured())

    Application.put_env(:harness, :dependency_bump_task_creator, fn _project, specs, _adapter, _model ->
      send(owner, {:created_specs, specs})
      {:ok, ["701"]}
    end)

    Application.put_env(:harness, :roadmap_ingest, fn {:id, "701"}, opts ->
      {:ok, %Harness.Roadmap.Item{id: "701", title: "deps", prompt: "prompt", agent: opts[:agent]}}
    end)

    Application.put_env(:harness, :dependency_bump_enqueuer, fn _project, item, _adapter, _opts ->
      {:ok, "run-#{item.id}", %Oban.Job{id: 701}}
    end)

    {:ok, view, _html} = live(conn, "/harness/deps/deps-update")

    view
    |> element("#dep-update-button")
    |> render_click()

    assert_received {:created_specs, [spec]}
    assert spec.body =~ "Ground-truth dependency freshness facts"
    assert spec.body =~ "req"
  end

  test "renders tooling baseline conformance facts", %{conn: conn} do
    project = ProjectFixture.from_repo("/tmp/harness-deps-conformance", name: "deps-conformance")
    :ok = ProjectRegistry.register(project)

    snapshot =
      Snapshot.build("deps-conformance", "elixir", [], conformance: conformance_snapshot())

    assert :ok = DepFreshnessStore.record_snapshot(snapshot, DepFreshnessStore.configured())

    {:ok, _view, html} = live(conn, "/harness/deps/deps-conformance")

    assert html =~ "Tooling baseline"
    assert html =~ "1 drift"
    assert html =~ "credo"
    assert html =~ "missing"
    assert html =~ "legacy stack"
    assert html =~ "Advisory (not enforced)"
    assert html =~ "PostToolUse hooks"
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

  @spec conformance_snapshot() :: ConformanceSnapshot.t()
  defp conformance_snapshot do
    ConformanceSnapshot.build(
      [
        %Item{id: "dep:credo", label: "credo", category: :dep, status: :missing},
        %Item{
          id: "dep:doctor",
          label: "doctor",
          category: :dep,
          status: :overridden,
          override_reason: "legacy stack"
        }
      ],
      [
        %Advisory{
          id: "post_tool_use_hooks",
          label: "PostToolUse hooks",
          description: "Operator-machine hook config; not in the committed project surface."
        }
      ]
    )
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
