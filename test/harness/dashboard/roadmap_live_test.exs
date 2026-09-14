defmodule Harness.Dashboard.RoadmapLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for `Harness.Dashboard.RoadmapLive` — the
  per-project roadmap rollup extracted from the runs dashboard onto its own
  `/harness/roadmap` page.

  `async: false` — reads the singleton `ProjectRegistry`, so a registered
  fixture project would leak across parallel tests.
  """

  # async: false because tests read singleton ProjectRegistry state.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    prev_list = Application.get_env(:harness, :roadmap_list)
    prev_next_bundle = Application.get_env(:harness, :roadmap_next_bundle)
    prev_ready = Application.get_env(:harness, :roadmap_ready)

    on_exit(fn ->
      restore(:roadmap_list, prev_list)
      restore(:roadmap_next_bundle, prev_next_bundle)
      restore(:roadmap_ready, prev_ready)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  describe "mount + render" do
    test "renders the no-projects state when the registry is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert html =~ "Roadmap"
      assert html =~ "No projects registered."
    end

    test "renders a per-project rollup row for a registered project", %{conn: conn} do
      project = ProjectFixture.from_repo("/tmp/harness-roadmaplive-demo", name: "roadmaplive-demo")
      :ok = ProjectRegistry.register(project)
      on_exit(fn -> ProjectRegistry.unregister(project.name) end)

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert html =~ "roadmaplive-demo"
      # The four rollup columns render (a /tmp path with no roadmap summarizes to
      # zeros, but the row + headers must be present).
      assert html =~ "Open"
      assert html =~ "Done"
      assert html =~ "Total"
      assert html =~ "Landed"
      assert html =~ "1 projects"
    end

    test "expands an empty project with explicit empty planning states", %{conn: conn} do
      project = ProjectFixture.from_repo("/tmp/harness-roadmaplive-empty", name: "roadmaplive-empty")
      :ok = ProjectRegistry.register(project)

      Application.put_env(:harness, :roadmap_list, fn _project -> {:ok, []} end)
      Application.put_env(:harness, :roadmap_next_bundle, fn _project -> {:ok, %{bundle: nil, tasks: []}} end)
      Application.put_env(:harness, :roadmap_ready, fn _project -> {:ok, []} end)

      {:ok, view, _html} = live(conn, "/harness/roadmap")

      html = view |> element("button", "roadmaplive-empty") |> render_click()

      assert html =~ "No next pending task."
      assert html =~ "No blocked tasks."
      assert html =~ "No dispatchable tasks."
    end

    test "expands a project with next task, blocked reasons, and dispatch waves", %{conn: conn} do
      project = ProjectFixture.from_repo("/tmp/harness-roadmaplive-planning", name: "roadmaplive-planning")
      :ok = ProjectRegistry.register(project)

      Application.put_env(:harness, :roadmap_list, fn _project ->
        {:ok,
         [
           %{"id" => "10", "status" => "pending", "title" => "Wire explicit refresh", "eff" => 1.25},
           %{
             "id" => "11",
             "status" => "blocked",
             "title" => "Repair branch drift",
             "blocked_reason" => "waiting on target branch"
           },
           %{
             "id" => "12",
             "status" => "blocked",
             "title" => "Unstick reviewer",
             "blocked_reason" => "reviewer unavailable"
           },
           %{"id" => "13", "status" => "done", "title" => "Already landed", "shipped_in" => "abc123"}
         ]}
      end)

      Application.put_env(:harness, :roadmap_next_bundle, fn _project ->
        {:ok, %{bundle: %{"name" => "dashboard"}, tasks: [%{"id" => "10", "title" => "Wire explicit refresh"}]}}
      end)

      Application.put_env(:harness, :roadmap_ready, fn _project ->
        {:ok,
         [
           %{"id" => "10", "title" => "Wire explicit refresh", "dep_layer" => 0, "eff" => 1.25},
           %{"id" => "14", "title" => "Polish empty state", "dep_layer" => 0, "eff" => 0.83},
           %{"id" => "15", "title" => "Follow-up wave", "dep_layer" => 1, "eff" => 1.5}
         ]}
      end)

      {:ok, view, _html} = live(conn, "/harness/roadmap")

      html = view |> element("button", "roadmaplive-planning") |> render_click()

      assert html =~ "Next pending"
      assert html =~ "#10"
      assert html =~ "Wire explicit refresh"
      assert html =~ "Blocked (2)"
      assert html =~ "waiting on target branch"
      assert html =~ "reviewer unavailable"
      assert html =~ "Wave 0"
      assert html =~ "Polish empty state"
      assert html =~ "Wave 1"
      assert html =~ "Follow-up wave"
      assert html =~ "Eff 1.25"
    end

    test "a roadmap tick with an unreachable origin never fetches and stays inside the drilldown timeout", %{
      conn: conn
    } do
      if !System.find_executable("rmap") do
        flunk("""
        rmap CLI not found on PATH.

        Harness.Dashboard.RoadmapLive shells out to `rmap` for drilldowns. Install
        it and ensure it is on PATH before running this suite.
        """)
      end

      test_pid = self()
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      {:ok, _acceptor} =
        Task.start(fn ->
          case :gen_tcp.accept(listen, 6_000) do
            {:ok, sock} ->
              send(test_pid, :origin_fetch_attempted)
              :gen_tcp.close(sock)

            {:error, _reason} ->
              :ok
          end
        end)

      on_exit(fn -> :gen_tcp.close(listen) end)

      %{repo: repo} = GitFixture.init_with_origin(name: "roadmaplive-nosync")
      sample = Path.expand("../../fixtures/sample_roadmap", __DIR__)
      File.cp_r!(Path.join(sample, "roadmap"), Path.join(repo, "roadmap"))
      GitFixture.git!(repo, ["add", "-A"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "seed roadmap"])
      GitFixture.git!(repo, ["push", "-q", "origin", "main"])
      GitFixture.git!(repo, ["remote", "set-url", "origin", "git://127.0.0.1:#{port}/unreachable.git"])

      project =
        ProjectFixture.from_repo(repo,
          name: "roadmaplive-nosync",
          target_branch: "main",
          roadmap_target_branch: "main"
        )

      :ok = ProjectRegistry.register(project)

      {elapsed_us, {:ok, view, html}} = :timer.tc(fn -> live(conn, "/harness/roadmap") end)

      assert elapsed_us < 5_000_000
      assert html =~ "roadmaplive-nosync"

      {tick_us, _tick_html} =
        :timer.tc(fn ->
          send(view.pid, :roadmap_tick)
          render(view)
        end)

      assert tick_us < 5_000_000
      refute_received :origin_fetch_attempted

      # The no-fetch assertion is only meaningful if the drilldown actually ran
      # the real (unseamed) `next_bundle` / `ready` path — an empty drilldown
      # would satisfy `refute_received` for the wrong reason.
      expanded = view |> element("button", "roadmaplive-nosync") |> render_click()

      assert expanded =~ "#2"
      assert expanded =~ "The next pending fixture task"
      refute_received :origin_fetch_attempted
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
