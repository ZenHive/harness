defmodule Harness.Dashboard.KPILiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for `Harness.Dashboard.KPILive` (Task 115):
  the aggregated per-agent ledger renders, the empty state is explicit (not a
  table of zeros), and the columns are sortable.

  `async: false` — the setup overrides the global `:result_store` config to an
  isolated tmp root so the aggregate-all ledger reflects only this test's seeded
  records, which would race a parallel module reading the store.
  """

  # async: false because tests mutate the global :result_store application env.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.CapabilityScore
  alias Harness.CapabilityScore.Assessment
  alias Harness.CapabilityScore.Entry
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
    test "overview renders an explicit empty ledger, not a table of zeros", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "No run records yet"
      refute html =~ "<tbody>"
      # The fleet strip is gated on having rows, so the empty state never shows it.
      # (The `.kpi-strip` *selector* is always in the stylesheet — match the element.)
      refute html =~ ~s(class="kpi-strip")
    end

    test "agents page renders the same empty ledger message", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi/agents")

      assert html =~ "No run records yet"
      refute html =~ ~s(phx-value-col="agent")
    end
  end

  describe "overview navigation" do
    setup do
      seed("run-c1", agent: :claude, verdict: :approve, review_iterations: 0, token_usage: tokens(100, 50))
      :ok
    end

    test "overview links through to the full agent ledger page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ ~s(href="/harness/kpi/agents")
      assert html =~ "Full ledger"
      refute html =~ ~s(phx-value-col="agent")
    end

    test "agents page links back to the KPI overview", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi/agents")

      assert html =~ ~s(href="/harness/kpi")
      assert html =~ "KPI overview"
    end
  end

  describe "aggregated ledger" do
    setup do
      seed("run-c1", agent: :claude, verdict: :approve, review_iterations: 0, token_usage: tokens(100, 50))
      seed("run-c2", agent: :claude, verdict: :reject, review_iterations: 1, token_usage: tokens(100, 50))
      seed("run-x1", agent: :codex, verdict: :approve, review_iterations: 0, token_usage: tokens(1000, 500))
      :ok
    end

    test "renders one row per agent with the rolled-up values on the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi/agents")

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

    test "renders the fleet summary strip with run-weighted headline numbers on the overview", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ ~s(class="kpi-strip")
      assert html =~ "Total runs"
      assert html =~ "Fleet success"
      # 3 runs, 2 agents; success = (claude 0.5×2 + codex 1.0×1) / 3 attributable = 67%.
      assert html =~ "67%"
      # Total spend = claude mean 150 × 2 + codex mean 1500 × 1 = 1,800 (thousands-grouped).
      assert html =~ "1,800"
    end

    test "renders rate columns as proportion bars with the value as the fill width on the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/harness/kpi/agents")

      assert html =~ "kpi-bar-fill tone-pass"
      # claude success 50% and codex success 100% become inline bar fill widths.
      assert html =~ ~s(style="width: 50%")
      assert html =~ ~s(style="width: 100%")
    end

    test "an agent with zero passes shows cost→green as a dash, not zero", %{conn: conn} do
      seed("run-g1", agent: :grok, verdict: :reject, review_iterations: 1, token_usage: tokens(10, 5))
      {:ok, _view, html} = live(conn, "/harness/kpi/agents")

      # grok has no passes — its cost→green cell renders the em-dash placeholder.
      assert html =~ "—"
    end

    test "renders a column per reviewer rating key with the per-agent mean", %{conn: conn} do
      # Two claude runs rated on the same keys; the ledger means them.
      seed("run-r1", agent: :grok, verdict: :approve, review_ratings: %{"performance" => 8, "idiom" => 6})
      seed("run-r2", agent: :grok, verdict: :approve, review_ratings: %{"performance" => 6, "idiom" => 10})

      {:ok, _view, html} = live(conn, "/harness/kpi/agents")

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
      {:ok, _view, html} = live(conn, "/harness/kpi/agents")

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

    test "renders orchestration-health review_stuck counts by persisted cause", %{conn: conn} do
      seed("run-selection-stuck",
        agent: :codex,
        verdict: nil,
        reason:
          {:review_stuck, "No cross-family reviewer adapter available: {:reviewer_unavailable, #{inspect(FakeAdapter)}}"},
        reviewer_adapter: nil
      )

      seed("run-driver-stuck",
        agent: :codex,
        verdict: nil,
        reason: {:review_stuck, :driver_crashed},
        reviewer_adapter: CursorReviewer
      )

      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "Orchestration health"
      assert html =~ "reviewer_unavailable"
      assert html =~ "driver_crashed"
      assert html =~ "Selection/no-reviewer stuck runs are counted here"
    end

    test "renders raw recovery facts with masked-failure rate and token cost", %{conn: conn} do
      seed("run-recovery-repaired",
        agent: :codex,
        recovery_attempts: 1,
        recovery_outcome: :repaired,
        recovery_repaired: "moved leaked checkout file",
        recovery_token_usage: tokens(20, 10)
      )

      seed("run-recovery-dead",
        agent: :claude,
        recovery_attempts: 1,
        recovery_outcome: :dead,
        recovery_token_usage: tokens(5, 5)
      )

      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "Recovery facts"
      assert html =~ "Masked-failure rate"
      assert html =~ "50%"
      assert html =~ "Recovery token cost"
      assert html =~ "40"
      assert html =~ "run-recovery-repaired"
      assert html =~ "repaired"
      assert html =~ "moved leaked checkout file"
      assert html =~ "run-recovery-dead"
      assert html =~ "dead"
    end

    test "columns are sortable on the agents page — clicking a header reorders the rows", %{conn: conn} do
      {:ok, view, html} = live(conn, "/harness/kpi/agents")

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

  describe "by task-facet pivot" do
    # Point the scout-artifact read at a per-test tmp root so the verdict column
    # never touches the operator's real ~/.harness assessment.
    setup do
      root = Path.join(System.tmp_dir!(), "harness_facet_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      prev = Application.get_env(:harness, :facet_assessment_root)
      Application.put_env(:harness, :facet_assessment_root, root)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:harness, :facet_assessment_root, prev),
          else: Application.delete_env(:harness, :facet_assessment_root)

        File.rm_rf(root)
      end)

      {:ok, facet_root: root}
    end

    test "groups the per-agent ledger by reviewer-assigned facet, untagged bucket included", %{conn: conn} do
      seed("run-otp", agent: :codex, verdict: :approve, review_facets: %{"surface" => "otp", "language" => "elixir"})
      seed("run-lv", agent: :claude, verdict: :approve, review_facets: %{"surface" => "liveview"})
      # No review_facets ⇒ defaults to %{} ⇒ the always-rendered unfaceted bucket.
      seed("run-bare", agent: :grok, verdict: :reject)

      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "By task-facet"
      assert html =~ "language=elixir · surface=otp"
      assert html =~ "surface=liveview"
      assert html =~ "Unfaceted"
    end

    test "renders the scout's verdict and highlights the winning agent row", %{conn: conn, facet_root: root} do
      seed("run-otp1", agent: :codex, verdict: :approve, review_facets: %{"surface" => "otp"})
      seed("run-otp2", agent: :claude, verdict: :reject, review_facets: %{"surface" => "otp"})

      assessment = %Assessment{
        assessed_at: ~U[2026-06-09 12:00:00Z],
        record_count: 2,
        entries: [
          %Entry{
            facet: %{"surface" => "otp"},
            winner: :codex,
            reasoning: "Codex wins OTP gen_statem work decisively.",
            by_agent: %{}
          }
        ]
      }

      :ok = CapabilityScore.save_assessment(assessment, assessment_root: root)

      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "Codex wins OTP gen_statem work decisively."
      assert html =~ "scout →"
      assert html =~ "scout assessed 2026-06-09"
      # The winning agent's row carries the winner class for the highlight.
      assert html =~ ~s(class="winner")
    end

    test "a facet with no scout entry shows the no-verdict placeholder", %{conn: conn} do
      seed("run-q", agent: :codex, verdict: :approve, review_facets: %{"surface" => "ecto"})

      {:ok, _view, html} = live(conn, "/harness/kpi")

      assert html =~ "no scout verdict yet"
    end

    test "clicking a facet pill filters to that one group", %{conn: conn} do
      seed("run-a", agent: :codex, verdict: :approve, review_facets: %{"surface" => "otp"})
      seed("run-b", agent: :claude, verdict: :approve, review_facets: %{"surface" => "liveview"})

      {:ok, view, html} = live(conn, "/harness/kpi")
      # Both facet cards present before filtering.
      assert html =~ "surface=otp"
      assert html =~ "surface=liveview"

      filtered = view |> element(~s|button[phx-value-key="surface=otp"]|) |> render_click()

      # The pill bar still lists every label, but only the otp CARD renders — the
      # liveview card's table is gone (its label survives only in the pill).
      assert filtered =~ ~s(class="facet-pill active")
      # Exactly one facet card table body remains (the filtered group).
      assert length(String.split(filtered, ~s(class="facet-card"))) == 2
    end
  end
end
