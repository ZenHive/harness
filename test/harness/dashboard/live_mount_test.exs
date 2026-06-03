defmodule Harness.Dashboard.LiveMountTest do
  @moduledoc """
  `Phoenix.LiveViewTest`-driven coverage for `Harness.Dashboard.Live` — mount,
  navigation, transcript `handle_info` branches, and event handlers. The pure
  helpers (`bucket_counts/1`, `filter_runs/2`, etc.) are covered as direct calls
  in `Harness.Dashboard.LiveTest`; this module exercises the live surface.

  `async: false` — reads the global `ProjectRegistry` and the run registry
  (`StatusView.snapshot/0`), and a registered fixture project / in-flight run
  would otherwise leak across parallel tests.
  """

  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Dashboard.Transcript
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Harness.Run

  setup %{conn: conn} do
    project = ProjectFixture.from_repo("/tmp/harness-livemount-demo", name: "livemount-demo")
    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)
    {:ok, conn: conn, project: project}
  end

  describe "index mount + render" do
    test "mounts the index, listing the registered project", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ "Active runs"
      assert html =~ "livemount-demo"
    end

    test "selecting a project pushes a filtering patch; clearing it patches back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/harness")

      view
      |> element("form[phx-change=select_project]")
      |> render_change(%{"project" => "livemount-demo"})

      assert_patch(view, "/harness?project=livemount-demo")

      view
      |> element("form[phx-change=select_project]")
      |> render_change(%{"project" => ""})

      assert_patch(view, "/harness")
    end
  end

  describe "index with an in-flight run" do
    setup do
      {run_id, _pid} = start_sleeping_run()
      %{run_id: run_id}
    end

    test "renders the run row with a kill control, and the kill button cancels it", %{
      conn: conn,
      run_id: run_id
    } do
      {:ok, view, html} = live(conn, "/harness")

      assert html =~ run_id
      assert html =~ "Kill run"

      # Click the run's kill button — routes through handle_event("kill_run", …)
      # → Harness.Run.cancel/1. Idempotent; settles the run :failed.
      view
      |> element("button[phx-value-run_id='#{run_id}']")
      |> render_click()

      assert Run.cancel(run_id) == :ok
    end
  end

  describe "run-detail (:show) navigation" do
    test "mounts the detail view for a live run, backfilling status + transcript", %{conn: conn} do
      {run_id, _pid} = start_sleeping_run()

      {:ok, _view, html} = live(conn, "/harness/runs/#{run_id}")

      assert html =~ "Run #{run_id}"
      assert html =~ "Transcript"
      # run_status was backfilled ({:ok, …}), so the field list renders (not the
      # "Run not found" branch).
      assert html =~ "Worktree path"
      assert html =~ "Verdict"
    end

    test "an unknown run id renders the not-found branch", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/runs/no-such-run")

      assert html =~ "Run not found"
    end

    test "the ?raw=1 param renders the raw stream pane", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/runs/no-such-run?raw=1")

      assert html =~ "view parsed turns"
      assert html =~ "Waiting for output…"
    end
  end

  describe "transcript handle_info branches" do
    setup %{conn: conn} do
      # Mount on a synthetic run id with ?raw=1: run_status backfills :not_found
      # (last_seq / events_last_seq stay 0), and the raw pane renders appended
      # chunks without needing the parsed-event view to accept arbitrary shapes.
      {:ok, view, _html} = live(conn, "/harness/runs/synthetic-run?raw=1")
      %{view: view}
    end

    test "raw chunks: cross-run drop, append, then stale-seq drop", %{view: view} do
      # cross-run: broadcast_run_id != assigns.run_id → dropped.
      send(view.pid, {:harness_transcript, "other-run", 1, "ignored"})
      # matching, seq 1 > last_seq 0 → appended.
      send(view.pid, {:harness_transcript, "synthetic-run", 1, "hello-stream"})
      # matching, seq 1 <= last_seq 1 → stale, dropped.
      send(view.pid, {:harness_transcript, "synthetic-run", 1, "DROPPED"})

      html = render(view)
      assert html =~ "hello-stream"
      refute html =~ "DROPPED"
      refute html =~ "ignored"
    end

    test "event deltas: cross-run, stale, empty, append, and cap-trim branches", %{view: view} do
      # cross-run drop
      send(view.pid, {:harness_transcript_events, "other-run", 1, [event("a")]})
      # empty list branch (no state change)
      send(view.pid, {:harness_transcript_events, "synthetic-run", 3, []})
      # append branch, events_last_seq → 5
      send(view.pid, {:harness_transcript_events, "synthetic-run", 5, [event("b")]})
      # stale branch, seq 4 <= events_last_seq 5 → dropped
      send(view.pid, {:harness_transcript_events, "synthetic-run", 4, [event("c")]})
      # over-cap append exercises trim_events_to_cap/2's drop branch
      cap = Transcript.event_count_cap()
      flood = for i <- 1..(cap + 1), do: event("flood-#{i}")
      send(view.pid, {:harness_transcript_events, "synthetic-run", 6, flood})

      # Force the mailbox to drain; raw view doesn't render events but the
      # handle_info clauses still execute.
      assert render(view) =~ "Run synthetic-run"
    end

    test ":meta_tick refreshes sidebar metadata without crashing on a not-found run", %{view: view} do
      send(view.pid, :meta_tick)
      assert render(view) =~ "Transcript"
    end
  end

  defp start_sleeping_run do
    base = GitFixture.tmp_base()
    repo = GitFixture.init_repo()
    project = ProjectFixture.from_repo(repo)

    {:ok, run_id, pid} =
      Run.Supervisor.start_run(item(), project, FakeAdapter,
        base_dir: base,
        adapter_opts: [command: :sleep],
        idle_timeout: 5_000,
        total_timeout: 10_000,
        lifetime_timeout: 30_000,
        terminal_linger: 100,
        subscriber: self()
      )

    on_exit(fn -> Run.cancel(run_id) end)
    {run_id, pid}
  end

  # Parser-event-shaped tuple; only the handle_info accounting is exercised here
  # (raw view never renders the parsed list), so the payload shape is incidental.
  defp event(text), do: {:assistant_text, %{text: text}}

  defp item do
    %Item{id: "50", title: "Dashboard mount coverage", prompt: "do the thing", agent: :claude}
  end
end
