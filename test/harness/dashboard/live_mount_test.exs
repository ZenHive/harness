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

  # async: false because tests read singleton ProjectRegistry and run registry state.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Dashboard.Transcript
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: MemoryStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter

  setup %{conn: conn} do
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_settings_store = Application.get_env(:harness, :settings_store)
    project = ProjectFixture.from_repo("/tmp/harness-livemount-demo", name: "livemount-demo")
    :ok = ProjectRegistry.register(project)

    on_exit(fn ->
      ProjectRegistry.unregister(project.name)
      restore_env(:repo_enabled, prior_repo_enabled)
      restore_env(:settings_store, prior_settings_store)
    end)

    {:ok, conn: conn, project: project}
  end

  describe "index mount + render" do
    test "mounts the index, listing the registered project", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ "Active runs"
      assert html =~ "livemount-demo"
    end

    test "renders a persistent no-op settings-store banner", %{conn: conn} do
      Application.put_env(:harness, :repo_enabled, false)
      Application.delete_env(:harness, :settings_store)

      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ "Settings are ephemeral"
      assert html =~ "will NOT survive a restart"
    end

    test "empty states report the fleet's condition, not a list's length", %{conn: conn} do
      {:ok, view, html} = live(conn, "/harness")

      assert html =~ ~s(class="empty-state")
      assert html =~ "The fleet is idle — no run is executing."
      assert html =~ "No merge or audit step has been reported since this page was opened."

      # Under a project filter the idle claim narrows to that project — the rest
      # of the fleet is out of the table's scope and so out of the sentence.
      view
      |> element("form[phx-change=select_project]")
      |> render_change(%{"project" => "livemount-demo"})

      filtered = render(view)
      assert filtered =~ "livemount-demo is idle — no run is executing."
      refute filtered =~ "The fleet is idle"
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

  describe "history empty-state text keys on the real condition (history_empty_reason/2)" do
    setup %{conn: conn} do
      # The LiveView reads ResultStore.configured/0; point it at a per-test tmp
      # store so the history ledger only sees what this test seeds (mirrors
      # KPILiveTest's isolation setup).
      root =
        Path.join(System.tmp_dir!(), "harness_history_empty_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      prev = Application.get_env(:harness, :result_store)
      Application.put_env(:harness, :result_store, {MemoryStore, root: root})

      on_exit(fn ->
        Application.put_env(:harness, :result_store, prev)
        File.rm_rf(root)
      end)

      {:ok, conn: conn}
    end

    test "no project selected, ledger empty: whole-ledger phrasing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ "No run has settled yet — the result ledger is empty."
    end

    test "a project selected, no settled runs for it: per-project phrasing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/harness")

      view
      |> element("form[phx-change=select_project]")
      |> render_change(%{"project" => "livemount-demo"})

      assert render(view) =~ "No run has settled yet for livemount-demo — the result ledger holds none."
    end

    test "settled runs exist but are all landed (hidden by the toggle): landed-only phrasing", %{
      conn: conn
    } do
      seed_history("hist-landed-1", task_id: "1", project_name: nil, landed_sha: "cafefeed")

      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ "Every settled run has landed — none is waiting to merge."
    end
  end

  describe "row action aria-label reflects known task/project context (row_action_aria_label/4)" do
    setup %{conn: conn} do
      root =
        Path.join(System.tmp_dir!(), "harness_aria_label_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      prev = Application.get_env(:harness, :result_store)
      Application.put_env(:harness, :result_store, {MemoryStore, root: root})

      on_exit(fn ->
        Application.put_env(:harness, :result_store, prev)
        File.rm_rf(root)
      end)

      {:ok, conn: conn}
    end

    test "run_id only — task_id and project_name unknown", %{conn: conn} do
      seed_history("aria-1", task_id: nil, project_name: nil)

      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ ~s(aria-label="Delete run aria-1")
    end

    test "task_id known, project_name unknown", %{conn: conn} do
      seed_history("aria-2", task_id: "77", project_name: nil)

      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ "aria-label=\"Delete run aria-2 (task 77)\""
    end

    test "task_id and project_name both known", %{conn: conn} do
      seed_history("aria-3", task_id: "78", project_name: "livemount-demo")

      {:ok, _view, html} = live(conn, "/harness")

      assert html =~ "aria-label=\"Delete run aria-3 (task 78, project livemount-demo)\""
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
      assert html =~ ~s(data-run-elapsed)
      refute html =~ ~s(data-run-elapsed>—</dd>)
    end

    test "an unknown run id renders the not-found branch", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/runs/no-such-run")

      assert html =~ "Run not found"
      refute html =~ ~s(class="run-detail-nav")
    end

    test "renders the sticky jump-nav and the collapsed run-internals disclosure", %{conn: conn} do
      {run_id, _pid} = start_sleeping_run()

      {:ok, _view, html} = live(conn, "/harness/runs/#{run_id}")

      # Jump-nav with anchors to each section (the Task link is conditional on a
      # resolved roadmap item, which this fixture run has none of).
      assert html =~ ~s(class="run-detail-nav")
      assert html =~ ~s(href="#run-info")
      assert html =~ ~s(href="#run-diff")
      assert html =~ ~s(href="#run-transcript")

      # Section anchors carry the scroll-margin class.
      assert html =~ ~s(id="run-info")
      assert html =~ ~s(id="run-transcript")

      # Low-traffic metadata moved behind the disclosure (still in the DOM).
      assert html =~ ~s(class="run-internals")
      assert html =~ "Run internals"
      assert html =~ "Worktree path"

      # Task 312 — stage stepper replaces bare state text.
      assert html =~ ~s(data-run-stage-stepper)
      assert html =~ ~s(data-status="current")
      refute html =~ ~r{<dt>State</dt>\s*<dd>(?:running|dispatched|reviewing)</dd>}
    end

    test "a settled run replays transcript usage into the token row", %{conn: conn} do
      run_id = "live-mount-tokens-#{System.unique_integer([:positive])}"
      usage_line = ~s({"type":"result","usage":{"input_tokens":7,"output_tokens":44}}\n)

      :ok =
        ResultStore.record_run(%LogRecord{
          batch_id: "batch-#{run_id}",
          run_id: run_id,
          task_id: "312",
          project_name: "livemount-demo",
          agent: :claude,
          adapter: Harness.Adapters.Claude,
          state: :done,
          reason: :approved,
          verdict: :approve,
          duration_ms: 1_000,
          review_iterations: 0,
          agent_output: usage_line
        })

      on_exit(fn -> ResultStore.delete_run(run_id) end)

      {:ok, _view, html} = live(conn, "/harness/runs/#{run_id}")

      assert html =~ ~s(data-stage="done" data-status="current")
      assert html =~ ">51<"
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

  describe "transcript chrome (Task 314)" do
    test "live run page surfaces activity, summary, heartbeat, and chip deltas", %{conn: conn} do
      {run_id, _pid} = start_sleeping_run()
      {:ok, view, _html} = live(conn, "/harness/runs/#{run_id}")

      events = [
        {:assistant_text, %{text: "working"}},
        {:assistant_tool_use,
         %{
           id: "1",
           name: "Edit",
           input: %{"file_path" => "js/src/coinbase.js", "old_string" => "a", "new_string" => "b\nc"}
         }},
        {:assistant_tool_use, %{id: "2", name: "Bash", input: %{"command" => "mix test"}}}
      ]

      send(view.pid, {:harness_transcript_events, run_id, 1, events})
      html = render(view)

      assert html =~ ~s(data-transcript-activity)
      assert html =~ "running mix test"
      assert html =~ ~s(data-transcript-summary)
      assert html =~ "1 turns"
      assert html =~ "2 tool calls"
      assert html =~ "1 files"
      assert html =~ ~s(data-transcript-heartbeat)
      assert html =~ "last output"
      assert html =~ "ago"
      assert html =~ "coinbase.js"
      assert html =~ "+2"
      assert html =~ "−1"

      send(view.pid, :meta_tick)
      assert render(view) =~ "last output"
    end
  end

  # Persists a settled (terminal-state) history record via the configured
  # ResultStore. Only the fields the history/aria-label surfaces care about are
  # overridable; the rest are inert defaults that satisfy @enforce_keys.
  @spec seed_history(String.t(), keyword()) :: :ok
  defp seed_history(run_id, fields) do
    base = %{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: Keyword.get(fields, :task_id, "t"),
      project_name: Keyword.get(fields, :project_name),
      adapter: FakeAdapter,
      state: :failed,
      reason: :cancelled,
      duration_ms: 100,
      landed_sha: Keyword.get(fields, :landed_sha)
    }

    :ok = ResultStore.record_run(struct!(LogRecord, base))
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

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
