defmodule Harness.Dashboard.CompareLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for `Harness.Dashboard.CompareLive` (Task 81):
  the launch form renders and validates, an unknown comparison id shows the
  empty state, a settled comparison reconstructs its lanes from `ResultStore`,
  and a live `RunFeed` update patches the correlated lane.

  `async: false` — overrides the global `:result_store` config to an isolated
  tmp root and registers a fixture project, both of which would race a parallel
  module reading the same globals.
  """

  # async: false because tests mutate :result_store env and ProjectRegistry state.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Harness.Run.Result, as: RunResult
  alias Harness.Run.Status
  alias Harness.TokenUsage

  @batch "compare-test-batch"

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "harness_compare_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, {ResultStore.Memory, root: root})

    project = ProjectFixture.from_repo("/tmp/harness-compare-live", name: "compare-live")
    :ok = ProjectRegistry.register(project)

    on_exit(fn ->
      ProjectRegistry.unregister(project.name)
      Application.put_env(:harness, :result_store, prev)
      File.rm_rf(root)
    end)

    {:ok, conn: conn, project: project}
  end

  describe "index — launch form" do
    test "renders the project, task, adapter, and submit controls", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/harness/compare")

      assert html =~ "A/B agent evaluation"
      assert html =~ project.name
      assert html =~ ~s(name="task_id")
      assert html =~ ~s(name="adapters[]")
      assert html =~ "Run comparison"
    end

    test "rejecting fewer than two adapters surfaces an error and does not redirect", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/harness/compare")

      html = submit(view, %{"project" => project.name, "task_id" => "7", "adapters" => ["claude"]})

      assert html =~ "Could not start comparison"
      assert html =~ "need_two_adapters"
    end

    test "an unknown project surfaces an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/harness/compare")

      html = submit(view, %{"project" => "nope", "task_id" => "7", "adapters" => ["claude", "codex"]})

      assert html =~ "Could not start comparison"
    end

    test "a blank task id is rejected before any dispatch", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/harness/compare")

      html = submit(view, %{"project" => project.name, "task_id" => "  ", "adapters" => ["claude", "codex"]})

      assert html =~ "Enter a task id."
    end
  end

  describe "show — reconstruction and live updates" do
    test "an unknown comparison id renders the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/compare/does-not-exist")

      assert html =~ "No live comparison for this id"
      assert html =~ ~s(href="/harness/compare")
    end

    test "a settled comparison reconstructs both lanes from the store", %{conn: conn} do
      seed(:claude, Claude, "r-green", verdict: :approve, state: :done, reason: :approved, duration_ms: 120)

      seed(:codex, Codex, "r-red",
        verdict: :reject,
        state: :failed,
        reason: {:review_rejected, "rejected"},
        duration_ms: 340
      )

      {:ok, _view, html} = live(conn, "/harness/compare/#{@batch}")

      assert html =~ "claude"
      assert html =~ "codex"
      assert html =~ ~s(data-verdict="pass")
      assert html =~ ~s(data-verdict="fail")
      assert html =~ "120 ms"
      assert html =~ "340 ms"
    end

    test "a live RunFeed update patches the correlated lane's reviewer verdict", %{conn: conn} do
      seed(:claude, Claude, "r-1", verdict: :approve, state: :done, reason: :approved)
      seed(:codex, Codex, "r-2", verdict: nil, state: :failed, reason: {:run_crashed, :boom})

      {:ok, view, _html} = live(conn, "/harness/compare/#{@batch}")

      # Before the update only the claude lane shows an approved verdict.
      # (Compare connected renders so the count is apples-to-apples.)
      approved_lanes = fn html -> length(String.split(html, ~s(data-verdict="pass"))) - 1 end
      before_count = approved_lanes.(render(view))
      assert before_count == 1

      status = %Status{
        run_id: "r-2",
        task_id: "t",
        agent: :codex,
        state: :reviewing,
        review_verdict: :approve
      }

      send(view.pid, {:harness_run_update, status})

      # The codex lane's verdict cell reflects the live reviewer verdict — proving
      # apply_status correlated the update by (task, agent).
      assert approved_lanes.(render(view)) == 2
    end

    test "a tab query param selects the active transcript lane", %{conn: conn} do
      seed(:claude, Claude, "r-a", verdict: :approve, state: :done, reason: :approved)
      seed(:codex, Codex, "r-b", verdict: :reject, state: :failed, reason: {:review_rejected, "rejected"})

      {:ok, _view, html} = live(conn, "/harness/compare/#{@batch}?tab=codex")

      assert html =~ "codex transcript"
    end

    test "a comparison_done error surfaces on the grid", %{conn: conn} do
      seed(:claude, Claude, "r-e1", verdict: :approve, state: :done, reason: :approved)
      seed(:codex, Codex, "r-e2", verdict: :reject, state: :failed, reason: {:review_rejected, "rejected"})

      {:ok, view, _html} = live(conn, "/harness/compare/#{@batch}")
      send(view.pid, {:comparison_done, {:error, "adapter exploded"}})

      assert render(view) =~ "Comparison failed"
    end

    test "a comparison_done success reconciles final per-adapter metrics", %{conn: conn} do
      seed(:claude, Claude, "r-s1", verdict: nil, state: :running, reason: :approved)
      seed(:codex, Codex, "r-s2", verdict: nil, state: :running, reason: :approved)

      {:ok, view, _html} = live(conn, "/harness/compare/#{@batch}")

      result = %RunResult{run_id: "r-final", task_id: "t", state: :done, reason: :approved}

      entry = %Entry{
        adapter: Codex,
        run_id: "r-final",
        state: :done,
        reason: :approved,
        verdict: :approve,
        duration_ms: 22,
        agent_diff_size: 11,
        reviewer_diff_size: 13,
        token_usage: %TokenUsage{total: 17},
        result: result
      }

      send(
        view.pid,
        {:comparison_done,
         {:ok, %Comparison{batch_id: @batch, task_id: "t", total: 2, max_concurrency: 2, entries: [entry]}}}
      )

      html = render(view)
      assert html =~ "22 ms"
      assert html =~ "11 B"
      assert html =~ "13 B"
      assert html =~ ">17<"
      assert html =~ ~s(data-verdict="pass")
    end

    test "settled status tracks a run and transcript updates are bounded by sequence", %{conn: conn} do
      seed(:claude, Claude, "r-t1", verdict: nil, state: :running, reason: :approved)
      seed(:codex, Codex, "r-t2", verdict: nil, state: :running, reason: :approved)

      {:ok, view, _html} = live(conn, "/harness/compare/#{@batch}?tab=codex")

      send(view.pid, {:harness_run_settled, %Status{run_id: "r-live", task_id: "t", agent: :codex, state: :reviewing}})
      assert render(view) =~ "reviewing"

      send(view.pid, {:harness_transcript_events, "r-live", 1, [{:assistant_text, %{text: "fresh output"}}]})
      send(view.pid, {:harness_transcript_events, "r-live", 1, [{:assistant_text, %{text: "stale output"}}]})

      html = render(view)
      assert html =~ "fresh output"
      refute html =~ "stale output"
    end
  end

  # Submits the launch form with explicit params (overriding the DOM-derived
  # values) so checkbox/select state is controlled per case.
  @spec submit(Phoenix.LiveViewTest.View.t(), map()) :: String.t()
  defp submit(view, params) do
    view |> element("form.compare-form") |> render_submit(params)
  end

  # Persists one LogRecord under @batch; task_id is shared ("t") so the lanes
  # correlate to one comparison. Only the comparison-relevant fields vary.
  @spec seed(atom(), module(), String.t(), keyword()) :: :ok
  defp seed(agent, adapter, run_id, fields) do
    record = %LogRecord{
      batch_id: @batch,
      run_id: run_id,
      task_id: "t",
      agent: agent,
      adapter: adapter,
      state: Keyword.get(fields, :state, :done),
      reason: Keyword.get(fields, :reason, :approved),
      verdict: Keyword.get(fields, :verdict),
      duration_ms: Keyword.get(fields, :duration_ms, 100),
      reviewer_diff_size: Keyword.get(fields, :reviewer_diff_size, 0),
      agent_diff_size: 42,
      token_usage: TokenUsage.empty(),
      agent_output: ""
    }

    ResultStore.record_run(record, ResultStore.configured())
  end
end
