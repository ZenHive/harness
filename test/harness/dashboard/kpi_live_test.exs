defmodule Harness.Dashboard.KPILiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for `Harness.Dashboard.KPILive` (Task 115):
  the aggregated per-agent ledger renders, the empty state is explicit (not a
  table of zeros), and the columns are sortable.

  `async: false` — the setup overrides the global `:result_store` config to an
  isolated tmp root so the aggregate-all ledger reflects only this test's seeded
  records, which would race a parallel module reading the store.
  """

  use Harness.Dashboard.ConnCase, async: false

  alias Harness.FakeAdapter
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  setup %{conn: conn} do
    # The LiveView reads ResultStore.configured/0; point it at a per-test tmp
    # File store so the ledger only sees what we seed, then restore + clean up.
    root = Path.join(System.tmp_dir!(), "harness_kpi_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, {ResultStore.Memory, root: root})

    on_exit(fn ->
      Application.put_env(:harness, :result_store, prev)
      File.rm_rf(root)
    end)

    {:ok, conn: conn}
  end

  # Persist one run record; only the KPI-relevant fields are overridable, the
  # rest are inert defaults that satisfy @enforce_keys.
  defp seed(run_id, fields) do
    base = %{
      batch_id: "batch-kpi",
      run_id: run_id,
      task_id: "t",
      adapter: FakeAdapter,
      state: :done,
      reason: :approved,
      duration_ms: 100,
      review_iterations: 0,
      token_usage: TokenUsage.empty()
    }

    :ok = ResultStore.record_run(struct!(LogRecord, Map.merge(base, Map.new(fields))))
  end

  defp tokens(input, output), do: %TokenUsage{input: input, output: output, total: input + output}

  # ai < bi ⇒ `a` is rendered before `b` in the table body.
  defp before?(html, a, b) do
    {ai, _} = :binary.match(html, a)
    {bi, _} = :binary.match(html, b)
    ai < bi
  end

  describe "no-data state" do
    test "renders an explicit empty ledger, not a table of zeros", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "No run records yet"
      refute html =~ "<tbody>"
    end
  end

  describe "aggregated ledger" do
    setup do
      seed("run-c1", agent: :claude, verdict: :approve, review_iterations: 0, token_usage: tokens(100, 50))
      seed("run-c2", agent: :claude, verdict: :reject, review_iterations: 1, token_usage: tokens(100, 50))
      seed("run-x1", agent: :codex, verdict: :approve, review_iterations: 0, token_usage: tokens(1000, 500))
      :ok
    end

    test "renders one row per agent with the rolled-up values", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "claude"
      assert html =~ "codex"
      assert html =~ "2 agents"

      # claude: 1/2 pass, 1/2 first-try, 0.5 mean repairs, mean tokens 150, cost→green 150.
      assert html =~ "50%"
      assert html =~ "0.50"
      assert html =~ "150"

      # codex: 1/1 pass, mean tokens 1500, cost→green 1500 (thousands-grouped).
      assert html =~ "100%"
      assert html =~ "1,500"
    end

    test "an agent with zero passes shows cost→green as a dash, not zero", %{conn: conn} do
      seed("run-g1", agent: :grok, verdict: :reject, review_iterations: 1, token_usage: tokens(10, 5))
      {:ok, _view, html} = live(conn, "/harness/kpi")

      # grok has no passes — its cost→green cell renders the em-dash placeholder.
      assert html =~ "—"
    end

    test "renders a column per reviewer rating key with the per-agent mean", %{conn: conn} do
      # Two claude runs rated on the same keys; the ledger means them.
      seed("run-r1", agent: :grok, verdict: :approve, review_ratings: %{"performance" => 8, "idiom" => 6})
      seed("run-r2", agent: :grok, verdict: :approve, review_ratings: %{"performance" => 6, "idiom" => 10})

      {:ok, _view, html} = live(conn, "/harness/kpi")

      # The free-form rating keys surface as humanized column headers…
      assert html =~ "Performance"
      assert html =~ "Idiom"
      # …and the means render (performance (8+6)/2 = 7.0, idiom (6+10)/2 = 8.0).
      assert html =~ "7.0"
      assert html =~ "8.0"
    end

    test "a reviewer-flaked run is excluded from the implementer's success and counted in its own column", %{
      conn: conn
    } do
      # codex's review_stuck run must not drag its success below 100% (1/1 gated),
      # and the reviewer-flaked count surfaces as its own column value.
      seed("run-flaked", agent: :codex, verdict: nil, reason: {:review_stuck, "no artifact"})
      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "Rvw flaked"
      # codex: 1 approve + 1 flaked → 100% success over 1 attributable run, flaked = 1.
      assert html =~ "100%"
    end

    test "renders the reviewer reliability table with rejection and no-verdict rates", %{conn: conn} do
      seed("run-rv1", agent: :codex, verdict: :approve, reviewer_adapter: CursorReviewer)

      seed("run-rv2",
        agent: :codex,
        verdict: nil,
        reason: {:review_stuck, "no artifact"},
        reviewer_adapter: CursorReviewer
      )

      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "Reviewer reliability"
      assert html =~ "CursorReviewer"
      assert html =~ "No-verdict rate"
      # Cursor gated 2, flaked 1 → 50% no-verdict rate.
      assert html =~ "50%"
    end

    test "columns are sortable — clicking a header reorders the rows", %{conn: conn} do
      {:ok, view, html} = live(conn, "/harness/kpi")

      # Default sort is run_count desc: claude (2 runs) leads codex (1 run).
      assert before?(html, "claude", "codex")

      # Sort by agent (new column ⇒ desc): "codex" > "claude", so codex leads.
      sorted = view |> element(~s|button[phx-value-col="agent"]|) |> render_click()
      assert before?(sorted, "codex", "claude")

      # Re-click flips to asc: claude leads again.
      resorted = view |> element(~s|button[phx-value-col="agent"]|) |> render_click()
      assert before?(resorted, "claude", "codex")
    end
  end
end
