defmodule Harness.ResultStore.KPILiveParityTest do
  @moduledoc """
  Golden parity: KPILive reviewer + facet numbers match across Memory and Postgres
  backends for the same seeded records (Task 258).
  """
  # async: false because DataCase uses SQL Sandbox shared mode and :result_store env.
  use Harness.DataCase, async: false
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.Repo
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: MemoryStore
  alias Harness.ResultStore.Postgres, as: PostgresStore
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  @moduletag :integration

  setup %{conn: conn} do
    Repo.delete_all(RunRecordSchema)

    file_root = Path.join(System.tmp_dir!(), "harness_kpi_live_parity_#{System.unique_integer([:positive])}")
    File.mkdir_p!(file_root)

    prev = Application.get_env(:harness, :result_store)

    on_exit(fn ->
      Application.put_env(:harness, :result_store, prev)
      MemoryStore.reset(root: file_root)
      File.rm_rf(file_root)
    end)

    {:ok, conn: conn, file_root: file_root}
  end

  test "KPILive renders identical reviewer and facet numbers on File and Postgres", %{
    conn: conn,
    file_root: file_root
  } do
    file_store = {MemoryStore, root: file_root}
    pg_store = {PostgresStore, repo: Repo}

    for store <- [file_store, pg_store], do: seed_records(store)

    file_html = render_kpi(conn, file_store)
    pg_html = render_kpi(conn, pg_store)

    for marker <- reviewer_markers() ++ facet_markers() do
      assert String.contains?(file_html, marker)
      assert String.contains?(pg_html, marker)
    end
  end

  defp render_kpi(conn, store) do
    prev = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, store)

    try do
      {:ok, _view, html} = live(conn, "/harness/kpi")
      html
    after
      Application.put_env(:harness, :result_store, prev)
    end
  end

  defp reviewer_markers do
    # Codex gated 2, flaked 1 → 50% no-verdict; 0% rejection.
    ["50%", "Reviewer reliability", inspect(Codex)]
  end

  defp facet_markers do
    # otp/elixir group: codex 100% approve; unfaceted grok 0% approve.
    ["language=elixir · surface=otp", "100%", "0%", "Unfaceted"]
  end

  defp seed_records(store) do
    records = [
      record("live-rv1", agent: :codex, verdict: :approve, reviewer_adapter: Codex),
      record("live-rv2",
        agent: :codex,
        verdict: nil,
        reason: {:review_stuck, "no artifact"},
        reviewer_adapter: Codex
      ),
      record("live-f1",
        agent: :codex,
        verdict: :approve,
        review_iterations: 0,
        review_facets: %{"surface" => "otp", "language" => "elixir"},
        token_usage: tokens(100, 50)
      ),
      record("live-f2",
        agent: :grok,
        verdict: :reject,
        review_facets: %{},
        token_usage: tokens(10, 5)
      )
    ]

    for rec <- records, do: assert(:ok = ResultStore.record_run(rec, store))
  end

  defp record(run_id, fields) do
    base = %{
      batch_id: "batch-kpi-live-parity",
      run_id: run_id,
      task_id: "t",
      adapter: Claude,
      state: :done,
      reason: :approved,
      duration_ms: 100,
      review_iterations: 0,
      token_usage: TokenUsage.empty()
    }

    struct!(LogRecord, Map.merge(base, Map.new(fields)))
  end

  defp tokens(input, output), do: %TokenUsage{input: input, output: output, total: input + output}
end
