defmodule Harness.Dashboard.RoadmapLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for the `/harness/roadmap` fleet task board.

  `async: false` — reads the singleton `ProjectRegistry` and application-env
  seams, so fixture projects would leak across parallel tests.
  """

  use Harness.Dashboard.ConnCase, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.TokenUsage

  defmodule UnavailableStore do
    @moduledoc false
    @spec list_run_records(keyword(), keyword()) :: {:error, :unavailable}
    def list_run_records(_filters, _opts), do: {:error, :unavailable}
  end

  setup do
    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    prev = %{
      list: Application.get_env(:harness, :roadmap_list),
      ready: Application.get_env(:harness, :roadmap_ready),
      live: Application.get_env(:harness, :task_board_live_runs),
      records: Application.get_env(:harness, :task_board_records),
      action: Application.get_env(:harness, :task_board_action)
    }

    on_exit(fn ->
      restore(:roadmap_list, prev.list)
      restore(:roadmap_ready, prev.ready)
      restore(:task_board_live_runs, prev.live)
      restore(:task_board_records, prev.records)
      restore(:task_board_action, prev.action)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  describe "mount + empty states" do
    test "renders the no-projects state when the registry is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert html =~ "Roadmap"
      assert html =~ "No projects registered."
    end

    test "renders every lane empty for a registered project with no tasks", %{conn: conn} do
      register("board-empty")
      stub_roadmap([], [])
      stub_execution("board-empty", [], [])

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert html =~ "board-empty"
      assert html =~ "Pending"
      assert html =~ "Implementing"
      assert html =~ "Reviewing"
      assert html =~ "Landing"
      assert html =~ "Blocked"
      assert html =~ "Done"
      assert html =~ "No pending tasks."
      assert html =~ "No implementing tasks."
      assert html =~ "No reviewing tasks."
      assert html =~ "No landing tasks."
      assert html =~ "No blocked tasks."
      assert html =~ "No recent done tasks."
      refute html =~ "urgency"
      refute html =~ "stuck"
    end
  end

  describe "lanes, dependencies, filter, and bounds" do
    test "renders every lane and dependency-ready vs waiting pending cards", %{conn: conn} do
      register("board-lanes", target_branch: "main")

      stub_roadmap(
        [
          task("1", "pending", "Ready wire"),
          Map.put(task("2", "pending", "Waiting on 1"), "depends_on", ["1"]),
          task("3", "in_progress", "Implementer running"),
          task("4", "in_progress", "Reviewer running"),
          task("5", "in_progress", "Approved unlanded"),
          task("6", "blocked", "Land cap"),
          task("7", "done", "Already shipped")
        ],
        ["1"]
      )

      stub_execution(
        "board-lanes",
        [
          status("run-impl", "3", :running, agent: :cursor, model: "composer"),
          status("run-rev", "4", :reviewing)
        ],
        [
          record("run-land", "5", :done, verdict: :approve, token_usage: %TokenUsage{total: 42, input: 40, output: 2}),
          record("run-block", "6", :done, verdict: :approve),
          record("run-done", "7", :done, verdict: :approve, landed_sha: "abc1234")
        ]
      )

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert card(html, "1", "pending") =~ "Ready wire"
      assert card(html, "1", "pending") =~ "Dependencies ready"
      assert card(html, "1", "pending") =~ "Dispatch"
      assert card(html, "2", "pending") =~ "Waiting on dependencies"
      refute card(html, "2", "pending") =~ "Dispatch"

      assert card(html, "3", "implementing") =~ "Implementer running"
      assert card(html, "3", "implementing") =~ "running"
      assert card(html, "3", "implementing") =~ "cursor"
      assert card(html, "3", "implementing") =~ "Hold"

      assert card(html, "4", "reviewing") =~ "Reviewer running"
      assert card(html, "4", "reviewing") =~ "reviewing"

      assert card(html, "5", "landing") =~ "Approved unlanded"
      assert card(html, "5", "landing") =~ "Land"
      assert card(html, "5", "landing") =~ "42"
      refute card(html, "5", "landing") =~ "Cost"

      assert card(html, "6", "blocked") =~ "Land cap"
      assert card(html, "6", "blocked") =~ "Re-land"

      assert card(html, "7", "done") =~ "Already shipped"
      refute card(html, "7", "done") =~ "Dispatch"
    end

    test "project filter hides the other project's cards", %{conn: conn} do
      register("alpha")
      register("beta")

      Application.put_env(:harness, :roadmap_list, fn
        %{name: "alpha"} -> {:ok, [task("1", "pending", "Alpha only")]}
        %{name: "beta"} -> {:ok, [task("2", "pending", "Beta only")]}
      end)

      Application.put_env(:harness, :roadmap_ready, fn _project -> {:ok, []} end)
      stub_execution("alpha", [], [])

      {:ok, view, html} = live(conn, "/harness/roadmap")
      assert html =~ "Alpha only"
      assert html =~ "Beta only"

      filtered = render_patch(view, "/harness/roadmap?project=alpha")
      assert filtered =~ "Alpha only"
      refute filtered =~ "Beta only"

      all =
        view
        |> form("#roadmap-project-filter", %{project: ""})
        |> render_change()

      assert all =~ "Alpha only"
      assert all =~ "Beta only"
    end

    test "Done history is bounded per project", %{conn: conn} do
      register("board-done")

      tasks = for i <- 1..25, do: task(Integer.to_string(i), "done", "Done #{i}")
      stub_roadmap(tasks, [])
      stub_execution("board-done", [], [])

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      {:ok, document} = Floki.parse_document(html)

      card_ids =
        document
        |> Floki.find("[data-task-card][data-lane=done]")
        |> Enum.map(fn node -> node |> Floki.attribute("data-task-id") |> List.first() end)

      assert Enum.count_until(card_ids, 21) == 20
      refute "1" in card_ids
    end

    test "renders held and failed as badges without a health score", %{conn: conn} do
      register("board-badges")

      stub_roadmap(
        [task("8", "in_progress", "Held impl"), task("9", "in_progress", "Failed impl")],
        []
      )

      stub_execution(
        "board-badges",
        [status("run-held", "8", :held, held?: true)],
        [record("run-failed", "9", :failed)]
      )

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      held = card(html, "8", "implementing")
      assert held =~ "data-badge=\"held\""
      assert held =~ "Resume"
      refute held =~ "priority"
      refute held =~ "urgency"

      failed = card(html, "9", "implementing")
      assert failed =~ "data-badge=\"failed\""
      assert failed =~ "Resume failed"
      assert failed =~ "Re-review"
      assert failed =~ "attempt run-failed"
    end

    test "an older approved attempt does not render a pending task as Done", %{conn: conn} do
      register("board-stale")
      stub_roadmap([task("24", "pending", "Still pending")], [])
      stub_execution("board-stale", [], [record("run-old-approve", "24", :done, verdict: :approve)])

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert card(html, "24", "pending") =~ "Still pending"
      assert card(html, "24", "pending") =~ "attempt run-old-approve"
      refute html =~ ~s(data-task-id="24") <> ~s( data-lane="done")
      refute html =~ ~s(data-lane="done" data-task-id="24")
    end

    test "a live-run update moves a pending card into Implementing without changing rmap status", %{conn: conn} do
      register("board-live")
      stub_roadmap([task("22", "pending", "Claimed late")], [])
      stub_execution("board-live", [], [])

      {:ok, view, html} = live(conn, "/harness/roadmap")
      assert card(html, "22", "pending") =~ "Claimed late"

      stub_execution("board-live", [status("run-live-p", "22", :running)], [])
      send(view.pid, {:harness_run_update, %{}})
      updated = render(view)

      assert card(updated, "22", "implementing") =~ "pending"
      assert card(updated, "22", "implementing") =~ "attempt run-live-p"
    end
  end

  describe "actions" do
    test "a successful dispatch refreshes the board and shows the existing ok notice", %{conn: conn} do
      register("board-actions")
      stub_roadmap([task("10", "pending", "Dispatch me")], ["10"])
      stub_execution("board-actions", [], [])

      parent = self()

      Application.put_env(:harness, :task_board_action, fn name, project, task_id, run_id ->
        send(parent, {:action, name, project, task_id, run_id})
        Application.put_env(:harness, :roadmap_list, fn _ -> {:ok, [task("10", "in_progress", "Dispatch me")]} end)
        Application.put_env(:harness, :roadmap_ready, fn _ -> {:ok, []} end)
        {:ok, "Dispatched task 10."}
      end)

      {:ok, view, html} = live(conn, "/harness/roadmap")
      assert html =~ "Dispatch"

      clicked =
        view
        |> element(~s(button[phx-click="dispatch_task"][phx-value-task_id="10"]))
        |> render_click()

      assert_received {:action, :dispatch, "board-actions", "10", nil}
      assert clicked =~ "Dispatched task 10."
      assert card(clicked, "10", "implementing") =~ "Dispatch me"
    end

    test "hold and land reuse the existing Dispatch seam and refresh on success", %{conn: conn} do
      register("board-run-actions", target_branch: "main")

      stub_roadmap(
        [task("3", "in_progress", "Hold me"), task("5", "in_progress", "Land me")],
        []
      )

      stub_execution(
        "board-run-actions",
        [status("run-impl", "3", :running)],
        [record("run-land", "5", :done, verdict: :approve)]
      )

      parent = self()

      Application.put_env(:harness, :task_board_action, fn name, project, task_id, run_id ->
        send(parent, {:action, name, project, task_id, run_id})
        {:ok, "#{name} ok"}
      end)

      {:ok, view, _html} = live(conn, "/harness/roadmap")

      held =
        view
        |> element(~s(button[phx-click="hold_run"][phx-value-run_id="run-impl"]))
        |> render_click()

      assert_received {:action, :hold, nil, nil, "run-impl"}
      assert held =~ "hold ok"

      landed =
        view
        |> element(~s(button[phx-click="land_run"][phx-value-run_id="run-land"]))
        |> render_click()

      assert_received {:action, :land, nil, nil, "run-land"}
      assert landed =~ "land ok"
    end

    test "resume, resume-failed, re-review, and re-land reuse the existing Dispatch seam", %{conn: conn} do
      register("board-recovery", target_branch: "main")

      stub_roadmap(
        [
          task("8", "in_progress", "Held"),
          task("9", "in_progress", "Failed"),
          task("6", "blocked", "Blocked")
        ],
        []
      )

      stub_execution(
        "board-recovery",
        [status("run-held", "8", :held, held?: true)],
        [
          record("run-failed", "9", :failed),
          record("run-block", "6", :done, verdict: :approve)
        ]
      )

      parent = self()

      Application.put_env(:harness, :task_board_action, fn name, project, task_id, run_id ->
        send(parent, {:action, name, project, task_id, run_id})
        {:ok, "#{name} ok"}
      end)

      {:ok, view, _html} = live(conn, "/harness/roadmap")

      view
      |> element(~s(button[phx-click="resume_held"][phx-value-run_id="run-held"]))
      |> render_click()

      assert_received {:action, :resume, nil, nil, "run-held"}

      view
      |> element(~s(button[phx-click="resume_failed"][phx-value-run_id="run-failed"]))
      |> render_click()

      assert_received {:action, :resume_failed, nil, nil, "run-failed"}

      view
      |> element(~s(button[phx-click="rereview_run"][phx-value-run_id="run-failed"]))
      |> render_click()

      assert_received {:action, :rereview, nil, nil, "run-failed"}

      relanded =
        view
        |> element(~s(button[phx-click="land_run"][phx-value-run_id="run-block"]))
        |> render_click()

      assert_received {:action, :land, nil, nil, "run-block"}
      assert relanded =~ "land ok"
    end

    test "a rejected action shows the error and does not move the card", %{conn: conn} do
      register("board-reject")
      stub_roadmap([task("11", "pending", "Stay pending")], ["11"])
      stub_execution("board-reject", [], [])

      Application.put_env(:harness, :task_board_action, fn _name, _project, _task_id, _run_id ->
        {:error, "Dispatch failed: :unavailable"}
      end)

      {:ok, view, _html} = live(conn, "/harness/roadmap")

      clicked =
        view
        |> element(~s(button[phx-click="dispatch_task"][phx-value-task_id="11"]))
        |> render_click()

      assert clicked =~ "Dispatch failed: :unavailable"
      assert card(clicked, "11", "pending") =~ "Stay pending"
    end
  end

  test "unavailable roadmap reads retain cards and expose the error", %{conn: conn} do
    register("board-unavailable")
    stub_roadmap([task("1", "pending", "Keep visible")], ["1"])
    stub_execution("board-unavailable", [], [])
    {:ok, view, _} = live(conn, "/harness/roadmap")
    Application.put_env(:harness, :roadmap_list, fn _ -> {:error, :rmap_failed} end)
    Application.put_env(:harness, :roadmap_ready, fn _ -> {:error, :rmap_failed} end)
    send(view.pid, :roadmap_tick)
    html = render(view)
    assert card(html, "1", "pending") =~ "Keep visible"
    assert html =~ "roadmap unavailable"
    assert html =~ "dispatch readiness unavailable"
    assert html =~ "rmap_failed"
    refute has_element?(view, "button[phx-click=dispatch_task]")
  end

  test "unavailable persisted results retain the last witnessed attempt", %{conn: conn} do
    register("board-store-error")
    stub_roadmap([task("1", "in_progress", "Keep landing")], [])
    stub_execution("board-store-error", [], [record("approved-run", "1", :done, verdict: :approve)])
    {:ok, view, _} = live(conn, "/harness/roadmap")
    previous = Application.get_env(:harness, :result_store)
    on_exit(fn -> restore(:result_store, previous) end)
    Application.delete_env(:harness, :task_board_records)
    Application.put_env(:harness, :result_store, {UnavailableStore, []})
    send(view.pid, {:harness_run_settled, %{}})
    html = render(view)
    assert card(html, "1", "landing") =~ "approved-run"
    assert html =~ "Run results unavailable: :unavailable"
  end

  test "settled elapsed time uses the measured duration even without terminal timestamps", %{conn: conn} do
    register("board-elapsed")
    stub_roadmap([task("1", "in_progress", "Measured duration")], [])
    settled = %{record("measured", "1", :done, verdict: :approve) | started_at: ~U[2020-01-01 00:00:00Z]}
    stub_execution("board-elapsed", [], [settled])
    {:ok, _view, html} = live(conn, "/harness/roadmap")
    {:ok, document} = html |> card("1", "landing") |> Floki.parse_document()
    elapsed = document |> Floki.find(".task-card-facts > div:nth-child(4) dd") |> Floki.text()
    assert elapsed == "1s"
  end

  describe "production contracts" do
    test "renders only supported Hold and recovery controls", %{conn: conn} do
      register("board-eligible")

      stub_roadmap(
        for(id <- ~w(1 2 3 4 5 6), do: task(id, "in_progress", "Task #{id}")),
        []
      )

      coalesced = %{record("coalesced", "3", :failed) | task_ids: ["3", "4"]}

      stub_execution(
        "board-eligible",
        [status("running", "1", :running), status("reviewing", "2", :reviewing)],
        [coalesced, record("landed", "5", :done, verdict: :approve, landed_sha: "abc"), record("failed", "6", :failed)]
      )

      {:ok, view, _html} = live(conn, "/harness/roadmap")
      assert has_element?(view, ~s(button[phx-click="hold_run"][phx-value-run_id="running"]))
      refute has_element?(view, ~s(button[phx-click="hold_run"][phx-value-run_id="reviewing"]))

      for run_id <- ["coalesced", "landed"], event <- ["resume_failed", "rereview_run"] do
        refute has_element?(view, ~s(button[phx-click="#{event}"][phx-value-run_id="#{run_id}"]))
      end

      assert has_element?(view, ~s(button[phx-click="resume_failed"][phx-value-run_id="failed"]))
      assert has_element?(view, ~s(button[phx-click="rereview_run"][phx-value-run_id="failed"]))
    end

    test "real Dispatch failures remain visible without changing task status", %{conn: conn} do
      register("board-contracts")
      stub_roadmap([task("1", "pending", "Unchanged")], [])
      stub_execution("board-contracts", [], [])
      {:ok, view, _} = live(conn, "/harness/roadmap")

      for event <- ["hold_run", "resume_held", "resume_failed", "rereview_run", "land_run"] do
        html = render_click(view, event, %{"run_id" => "missing-board-contract-run"})
        assert html =~ "not_found"
        assert card(html, "1", "pending") =~ "Unchanged"
      end

      html = render_click(view, "dispatch_task", %{"project" => "missing-board-project", "task_id" => "1"})
      assert html =~ "unknown_project"
      assert card(html, "1", "pending") =~ "Unchanged"
    end

    test "settled landing facts survive more than 200 unrelated results", %{conn: conn} do
      register("quiet-project")
      stub_roadmap([task("1", "in_progress", "Still needs landing")], [])
      previous = Application.get_env(:harness, :result_store)
      store = {Harness.ResultStore.Memory, scope: make_ref()}
      Application.put_env(:harness, :result_store, store)
      on_exit(fn -> restore(:result_store, previous) end)

      :ok =
        Harness.ResultStore.record_run(record("quiet-run", "1", :done, project_name: "quiet-project", verdict: :approve))

      for i <- 1..201 do
        :ok = Harness.ResultStore.record_run(record("busy-#{i}", to_string(i), :failed, project_name: "busy-project"))
      end

      {:ok, _view, html} = live(conn, "/harness/roadmap")
      assert card(html, "1", "landing") =~ "quiet-run"
    end
  end

  describe "rmap display reads" do
    test "a roadmap tick with an unreachable origin never fetches and stays inside the drilldown timeout", %{
      conn: conn
    } do
      if !System.find_executable("rmap") do
        flunk("""
        rmap CLI not found on PATH.

        Harness.Dashboard.RoadmapLive shells out to `rmap` for board facts. Install
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
      stub_execution("roadmaplive-nosync", [], [])

      {elapsed_us, {:ok, view, html}} = :timer.tc(fn -> live(conn, "/harness/roadmap") end)

      assert elapsed_us < 5_000_000
      assert html =~ "roadmaplive-nosync"
      assert html =~ "#2"
      assert html =~ "The next pending fixture task"

      {tick_us, _tick_html} =
        :timer.tc(fn ->
          send(view.pid, :roadmap_tick)
          render(view)
        end)

      assert tick_us < 5_000_000
      refute_received :origin_fetch_attempted
    end
  end

  defp register(name, opts \\ []) do
    project = ProjectFixture.from_repo("/tmp/harness-#{name}", Keyword.merge([name: name], opts))
    :ok = ProjectRegistry.register(project)
    project
  end

  defp stub_roadmap(tasks, ready_ids) do
    Application.put_env(:harness, :roadmap_list, fn _project -> {:ok, tasks} end)

    ready = Enum.map(ready_ids, fn id -> %{"id" => id} end)
    Application.put_env(:harness, :roadmap_ready, fn _project -> {:ok, ready} end)
  end

  defp stub_execution(project_name, live_runs, records) when is_binary(project_name) do
    live = Enum.map(live_runs, fn status -> %{status | project_name: project_name} end)
    recs = Enum.map(records, fn record -> %{record | project_name: project_name} end)
    Application.put_env(:harness, :task_board_live_runs, fn -> live end)
    Application.put_env(:harness, :task_board_records, fn -> recs end)
  end

  defp task(id, status, title) do
    %{"id" => id, "status" => status, "title" => title, "depends_on" => []}
  end

  defp status(run_id, task_id, state, opts \\ []) do
    struct!(
      %Status{
        run_id: run_id,
        task_id: task_id,
        state: state,
        project_name: Keyword.get(opts, :project_name, current_project_name(opts))
      },
      Keyword.delete(opts, :project_name)
    )
  end

  defp current_project_name(opts), do: Keyword.get(opts, :project_name, "board-lanes")

  defp record(run_id, task_id, state, opts \\ []) do
    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: task_id,
      project_name: Keyword.get(opts, :project_name, "board-lanes"),
      adapter: FakeAdapter,
      state: state,
      reason: Keyword.get(opts, :reason, :approved),
      verdict: Keyword.get(opts, :verdict),
      duration_ms: 1_000,
      landed_sha: Keyword.get(opts, :landed_sha),
      token_usage: Keyword.get(opts, :token_usage, TokenUsage.empty())
    }
  end

  defp card(html, task_id, lane) do
    {:ok, document} = Floki.parse_document(html)

    match =
      document
      |> Floki.find("[data-task-card]")
      |> Enum.find(fn node ->
        Floki.attribute(node, "data-task-id") == [task_id] and Floki.attribute(node, "data-lane") == [lane]
      end)

    assert match, "expected card task #{task_id} in #{lane} lane"
    Floki.raw_html(match)
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
