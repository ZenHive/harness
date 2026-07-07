defmodule Harness.ResultStore.KPIParityTest do
  @moduledoc """
  Golden parity: Memory in-process rollup vs Postgres SQL aggregate (Task 139).
  """
  # async: false because DataCase uses SQL Sandbox shared mode and :result_store env.
  use Harness.DataCase, async: false

  import Ecto.Query

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentKPI
  alias Harness.CapabilityScore
  alias Harness.Repo
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: MemoryStore
  alias Harness.ResultStore.Postgres, as: PostgresStore
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  @moduletag :integration
  @hours_per_day 24
  @retention_ms to_timeout(hour: @hours_per_day)
  @old_record_age_retention_periods 2
  @old_record_age_ms @retention_ms * @old_record_age_retention_periods
  @fresh_record_age_divisor 2
  @fresh_record_age_ms div(@retention_ms, @fresh_record_age_divisor)

  setup do
    Repo.delete_all(RunRecordSchema)
    prev = Application.get_env(:harness, :result_store)
    root = Path.join(System.tmp_dir!(), "harness_kpi_parity_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.put_env(:harness, :result_store, prev)
      MemoryStore.reset(root: root)
    end)

    {:ok, root: root}
  end

  defp seed_records(store) do
    records = [
      record("parity-c1",
        agent: :claude,
        verdict: :approve,
        review_iterations: 0,
        duration_ms: 100,
        token_usage: tokens(100, 50),
        review_ratings: %{"performance" => 8, "idiom" => 6}
      ),
      record("parity-c2",
        agent: :claude,
        verdict: :reject,
        review_iterations: 1,
        duration_ms: 300,
        token_usage: tokens(100, 50),
        review_ratings: %{"performance" => 6, "idiom" => 10}
      ),
      record("parity-x1",
        agent: :codex,
        verdict: :approve,
        review_iterations: 0,
        duration_ms: 50,
        token_usage: tokens(1000, 500),
        review_skills: %{
          "otp" => %{"score" => 8, "note" => "clean process boundary"},
          "truthfulness" => %{"score" => 9, "note" => "report matched evidence"}
        }
      ),
      # A reviewer-flaked codex run: the SQL and in-memory rollups must agree that
      # this is excluded from codex's success denominator, not a non-pass.
      record("parity-x2",
        agent: :codex,
        verdict: nil,
        reason: {:review_stuck, "no artifact"},
        review_iterations: 0,
        duration_ms: 70,
        token_usage: tokens(200, 100)
      )
    ]

    for rec <- records, do: assert(:ok = ResultStore.record_run(rec, store))
    records
  end

  test "aggregate_by_agent matches Memory in-process rollup for the same records", %{root: root} do
    file_store = {MemoryStore, root: root}
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
               record("parity-huge", agent_output: huge, verdict: :approve),
               pg_store
             )

    assert {:ok, [listed]} = ResultStore.list_run_records(pg_store, [])
    assert listed.agent_output == ""

    assert {:ok, [point]} = ResultStore.list_run_records(pg_store, run_id: "parity-huge")
    assert byte_size(point.agent_output) == 50_000
  end

  test "transcript retention strips only blobs while aggregates and point lookups keep working", %{} do
    pg_store = {PostgresStore, repo: Repo}

    records = [
      record("retention-old-approve",
        agent: :codex,
        verdict: :approve,
        reviewer_adapter: Codex,
        reviewer_model: "gpt-5.5",
        review_facets: %{"surface" => "otp"},
        token_usage: tokens(100, 50),
        agent_output: "old implementer transcript",
        reviewer_output: "old reviewer transcript"
      ),
      record("retention-old-reject",
        agent: :claude,
        verdict: :reject,
        reviewer_adapter: Claude,
        reviewer_model: "opus",
        review_facets: %{"surface" => "otp"},
        token_usage: tokens(80, 40),
        agent_output: "older implementer transcript",
        reviewer_output: "older reviewer transcript"
      ),
      record("retention-fresh",
        agent: :codex,
        verdict: nil,
        reason: {:review_stuck, "no artifact"},
        reviewer_adapter: Codex,
        reviewer_model: "gpt-5.5",
        review_facets: %{"surface" => "ui"},
        token_usage: tokens(20, 10),
        agent_output: "fresh implementer transcript",
        reviewer_output: "fresh reviewer transcript"
      )
    ]

    for rec <- records, do: assert(:ok = ResultStore.record_run(rec, pg_store))

    now = ~N[2026-07-07 12:00:00.000000]
    old_at = NaiveDateTime.add(now, -@old_record_age_ms, :millisecond)
    fresh_at = NaiveDateTime.add(now, -@fresh_record_age_ms, :millisecond)

    set_inserted_at(["retention-old-approve", "retention-old-reject"], old_at)
    set_inserted_at(["retention-fresh"], fresh_at)

    before_strip = aggregate_snapshot(pg_store)

    assert {:ok, 2} =
             PostgresStore.strip_old_transcript_blobs(
               repo: Repo,
               retention_ms: @retention_ms,
               now: now
             )

    assert aggregate_snapshot(pg_store) == before_strip

    assert {:ok, [stripped]} = ResultStore.list_run_records(pg_store, run_id: "retention-old-approve")
    assert stripped.agent_output == ""
    assert stripped.reviewer_output == ""
    assert stripped.verdict == :approve
    assert stripped.review_facets == %{"surface" => "otp"}

    assert {:ok, [fresh]} = ResultStore.list_run_records(pg_store, run_id: "retention-fresh")
    assert fresh.agent_output == "fresh implementer transcript"
    assert fresh.reviewer_output == "fresh reviewer transcript"
  end

  test "aggregate_reviewer_reliability matches Memory in-process rollup for the same records", %{root: root} do
    file_store = {MemoryStore, root: root}
    pg_store = {PostgresStore, repo: Repo}

    records = seed_reviewer_records(file_store)
    seed_reviewer_records(pg_store)

    file_ledger = AgentKPI.aggregate_reviewer_rejections(records)
    assert {:ok, pg_ledger} = ResultStore.aggregate_reviewer_reliability(pg_store)

    assert pg_ledger |> Map.keys() |> Enum.sort() == file_ledger |> Map.keys() |> Enum.sort()

    for reviewer <- Map.keys(file_ledger) do
      assert_reviewer_equal(file_ledger[reviewer], pg_ledger[reviewer])
    end
  end

  test "aggregate_by_facet matches Memory in-process rollup for the same records", %{root: root} do
    file_store = {MemoryStore, root: root}
    pg_store = {PostgresStore, repo: Repo}

    records = seed_facet_records(file_store)
    seed_facet_records(pg_store)

    file_groups =
      records
      |> CapabilityScore.build_scout_context()
      |> Enum.map(fn %{facet: facet, by_agent: agents} -> %{facet: facet, agents: agents} end)
      |> Enum.sort_by(&Jason.encode!(Map.get(&1, :facet, %{})))

    assert {:ok, pg_groups} = ResultStore.aggregate_by_facet(pg_store)
    pg_groups = Enum.sort_by(pg_groups, &Jason.encode!(Map.get(&1, :facet, %{})))

    assert length(pg_groups) == length(file_groups)

    file_groups
    |> Enum.zip(pg_groups)
    |> Enum.each(fn {file_group, pg_group} ->
      assert file_group.facet == pg_group.facet
      assert file_group.agents |> Map.keys() |> Enum.sort() == pg_group.agents |> Map.keys() |> Enum.sort()

      for agent <- Map.keys(file_group.agents) do
        assert_kpi_equal(file_group.agents[agent], pg_group.agents[agent])
      end
    end)
  end

  test "list_run_records respects :limit and inserted_at recency", %{} do
    pg_store = {PostgresStore, repo: Repo}

    for id <- ["parity-old", "parity-mid", "parity-new"] do
      assert :ok = ResultStore.record_run(record(id, verdict: :approve), pg_store)
      Process.sleep(5)
    end

    assert {:ok, ids} =
             pg_store
             |> ResultStore.list_run_records(limit: 2)
             |> then(fn {:ok, rows} -> {:ok, Enum.map(rows, & &1.run_id)} end)

    assert ids == ["parity-new", "parity-mid"]
  end

  defp seed_reviewer_records(store) do
    records = [
      record("parity-rv1", agent: :codex, verdict: :approve, reviewer_adapter: Codex),
      record("parity-rv2",
        agent: :codex,
        verdict: nil,
        reason: {:review_stuck, "no artifact"},
        reviewer_adapter: Codex
      ),
      record("parity-rv3", agent: :claude, verdict: :reject, reviewer_adapter: Claude)
    ]

    for rec <- records, do: assert(:ok = ResultStore.record_run(rec, store))
    records
  end

  defp seed_facet_records(store) do
    records = [
      record("parity-f1",
        agent: :codex,
        verdict: :approve,
        review_iterations: 0,
        review_facets: %{"surface" => "otp", "language" => "elixir"},
        token_usage: tokens(100, 50)
      ),
      record("parity-f2",
        agent: :claude,
        verdict: :reject,
        review_iterations: 1,
        review_facets: %{"surface" => "otp", "language" => "elixir"},
        token_usage: tokens(80, 40)
      ),
      record("parity-f3",
        agent: :grok,
        verdict: :reject,
        review_facets: %{},
        token_usage: tokens(10, 5)
      )
    ]

    for rec <- records, do: assert(:ok = ResultStore.record_run(rec, store))
    records
  end

  defp aggregate_snapshot(store) do
    assert {:ok, by_agent} = ResultStore.aggregate_by_agent(store)
    assert {:ok, reviewers} = ResultStore.aggregate_reviewer_reliability(store)
    assert {:ok, facets} = ResultStore.aggregate_by_facet(store)

    %{by_agent: by_agent, reviewers: reviewers, facets: facets}
  end

  defp set_inserted_at(run_ids, inserted_at) do
    Repo.update_all(
      from(r in RunRecordSchema, where: r.run_id in ^run_ids),
      set: [inserted_at: inserted_at, updated_at: inserted_at]
    )
  end

  defp assert_reviewer_equal(a, b) do
    assert a.reviewed_count == b.reviewed_count
    assert a.rejection_count == b.rejection_count
    assert a.no_verdict_count == b.no_verdict_count
    assert a.false_approval_count == b.false_approval_count
    assert_in_delta(a.rejection_rate, b.rejection_rate, 1.0e-9)
    assert_in_delta(a.no_verdict_rate, b.no_verdict_rate, 1.0e-9)
    assert_in_delta(a.false_approval_rate, b.false_approval_rate, 1.0e-9)
    assert Map.keys(a.by_model) == Map.keys(b.by_model)

    for key <- Map.keys(a.by_model) do
      assert_reviewer_model_equal(a.by_model[key], b.by_model[key])
    end
  end

  defp assert_reviewer_model_equal(a, b) do
    assert a.reviewed_count == b.reviewed_count
    assert a.rejection_count == b.rejection_count
    assert a.no_verdict_count == b.no_verdict_count
    assert a.false_approval_count == b.false_approval_count
    assert_in_delta(a.rejection_rate, b.rejection_rate, 1.0e-9)
    assert_in_delta(a.no_verdict_rate, b.no_verdict_rate, 1.0e-9)
    assert_in_delta(a.false_approval_rate, b.false_approval_rate, 1.0e-9)
  end

  defp assert_kpi_equal(a, b) do
    assert a.run_count == b.run_count
    assert a.reviewer_flaked == b.reviewer_flaked
    assert_in_delta(a.success_rate, b.success_rate, 1.0e-9)
    assert_in_delta(a.first_attempt_pass_rate, b.first_attempt_pass_rate, 1.0e-9)
    assert_in_delta(a.duration_ms.median, b.duration_ms.median, 1.0e-9)
    assert a.duration_ms.p90 == b.duration_ms.p90
    assert_in_delta(a.tokens.input, b.tokens.input, 1.0e-9)
    assert_in_delta(a.tokens.output, b.tokens.output, 1.0e-9)
    assert_in_delta(a.tokens.total, b.tokens.total, 1.0e-9)
    assert_in_delta(a.review_iterations, b.review_iterations, 1.0e-9)

    assert a.ratings |> Map.keys() |> Enum.sort() == b.ratings |> Map.keys() |> Enum.sort()

    for key <- Map.keys(a.ratings) do
      assert_in_delta(a.ratings[key], b.ratings[key], 1.0e-9)
    end

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
      reason: :approved,
      duration_ms: 100,
      review_iterations: 0,
      token_usage: TokenUsage.empty()
    }

    struct!(LogRecord, Map.merge(base, Map.new(fields)))
  end

  defp tokens(input, output), do: %TokenUsage{input: input, output: output, total: input + output}
end
