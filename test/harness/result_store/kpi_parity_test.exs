defmodule Harness.ResultStore.KPIParityTest do
  @moduledoc """
  Golden parity: File in-memory rollup vs Postgres SQL aggregate (Task 139).
  """
  use Harness.DataCase, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentKPI
  alias Harness.Repo
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Harness.ResultStore.Postgres, as: PostgresStore
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  @moduletag :integration

  setup do
    Repo.delete_all(RunRecordSchema)
    prev = Application.get_env(:harness, :result_store)
    root = Path.join(System.tmp_dir!(), "harness_kpi_parity_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      Application.put_env(:harness, :result_store, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp seed_records(store) do
    records = [
      record("parity-c1",
        agent: :claude,
        verdict: :pass,
        review_iterations: 0,
        duration_ms: 100,
        token_usage: tokens(100, 50)
      ),
      record("parity-c2",
        agent: :claude,
        verdict: :fail,
        review_iterations: 1,
        duration_ms: 300,
        token_usage: tokens(100, 50)
      ),
      record("parity-x1",
        agent: :codex,
        verdict: :pass,
        review_iterations: 0,
        duration_ms: 50,
        token_usage: tokens(1000, 500)
      )
    ]

    for rec <- records, do: assert(:ok = ResultStore.record_run(rec, store))
    records
  end

  test "aggregate_by_agent matches File in-memory rollup for the same records", %{root: root} do
    file_store = {FileStore, root: root}
    pg_store = {PostgresStore, repo: Repo}

    records = seed_records(file_store)
    seed_records(pg_store)

    file_ledger = AgentKPI.aggregate(records)
    assert {:ok, pg_ledger} = ResultStore.aggregate_by_agent(pg_store)

    assert pg_ledger |> Map.keys() |> Enum.sort() == file_ledger |> Map.keys() |> Enum.sort()

    for agent <- Map.keys(file_ledger) do
      assert_kpi_equal(file_ledger[agent], pg_ledger[agent])
    end
  end

  test "list_run_records omits agent_output unless run_id pins a single row", %{} do
    pg_store = {PostgresStore, repo: Repo}
    huge = :binary.copy(<<0>>, 50_000)

    assert :ok =
             ResultStore.record_run(
               record("parity-huge", agent_output: huge, verdict: :pass),
               pg_store
             )

    assert {:ok, [listed]} = ResultStore.list_run_records(pg_store, [])
    assert listed.agent_output == ""

    assert {:ok, [point]} = ResultStore.list_run_records(pg_store, run_id: "parity-huge")
    assert byte_size(point.agent_output) == 50_000
  end

  test "list_run_records respects :limit and inserted_at recency", %{} do
    pg_store = {PostgresStore, repo: Repo}

    for id <- ["parity-old", "parity-mid", "parity-new"] do
      assert :ok = ResultStore.record_run(record(id, verdict: :pass), pg_store)
      Process.sleep(5)
    end

    assert {:ok, ids} =
             pg_store
             |> ResultStore.list_run_records(limit: 2)
             |> then(fn {:ok, rows} -> {:ok, Enum.map(rows, & &1.run_id)} end)

    assert ids == ["parity-new", "parity-mid"]
  end

  defp assert_kpi_equal(a, b) do
    assert a.run_count == b.run_count
    assert_in_delta(a.success_rate, b.success_rate, 1.0e-9)
    assert_in_delta(a.first_attempt_pass_rate, b.first_attempt_pass_rate, 1.0e-9)
    assert_in_delta(a.duration_ms.median, b.duration_ms.median, 1.0e-9)
    assert a.duration_ms.p90 == b.duration_ms.p90
    assert_in_delta(a.tokens.input, b.tokens.input, 1.0e-9)
    assert_in_delta(a.tokens.output, b.tokens.output, 1.0e-9)
    assert_in_delta(a.tokens.total, b.tokens.total, 1.0e-9)
    assert_in_delta(a.review_iterations, b.review_iterations, 1.0e-9)

    case {a.cost_to_green, b.cost_to_green} do
      {nil, nil} -> :ok
      {fa, fb} when is_float(fa) and is_float(fb) -> assert_in_delta(fa, fb, 1.0e-9)
    end
  end

  defp record(run_id, fields) do
    base = %{
      batch_id: "batch-parity",
      run_id: run_id,
      task_id: "t",
      adapter: Claude,
      state: :done,
      reason: :passed,
      duration_ms: 100,
      review_iterations: 0,
      first_attempt_failed_check_count: 0,
      failure_cause: %{reason: :passed, failed_checks: []},
      token_usage: TokenUsage.empty()
    }

    struct!(LogRecord, Map.merge(base, Map.new(fields)))
  end

  defp tokens(input, output), do: %TokenUsage{input: input, output: output, total: input + output}
end
