defmodule Harness.ResultStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentKPI
  alias Harness.CapabilityScore
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: Store
  alias Harness.ResultStoreContract

  setup do
    scope = "memory-#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.reset(scope: scope) end)
    {:ok, store: {Store, scope: scope}}
  end

  describe "ResultStore contract" do
    test "passes the shared CRUD contract", %{store: store} do
      assert :ok = ResultStoreContract.assert_crud_roundtrips(store)
    end

    test "roundtrips complex fields", %{store: store} do
      assert :ok = ResultStoreContract.assert_complex_fields(store)
    end

    test "delete_run removes one record idempotently", %{store: store} do
      assert :ok = ResultStoreContract.assert_delete_run(store)
    end
  end

  test "aggregate_reviewer_reliability matches AgentKPI over the in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-rv1",
        verdict: :reject,
        reviewer_adapter: Claude
      ),
      ResultStoreContract.log_record(
        run_id: "mem-rv2",
        verdict: nil,
        reason: {:review_stuck, "no artifact"},
        reviewer_adapter: Claude
      )
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, ledger} = ResultStore.aggregate_reviewer_reliability(store)
    assert ledger == AgentKPI.aggregate_reviewer_rejections(records)
  end

  test "aggregate_by_facet matches CapabilityScore.build_scout_context/1", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-f1",
        agent: :codex,
        verdict: :approve,
        review_facets: %{"surface" => "otp"}
      ),
      ResultStoreContract.log_record(run_id: "mem-f2", agent: :grok, verdict: :reject, review_facets: %{})
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    expected =
      records
      |> CapabilityScore.build_scout_context()
      |> Enum.map(fn %{facet: facet, by_agent: agents} -> %{facet: facet, agents: agents} end)

    assert {:ok, groups} = ResultStore.aggregate_by_facet(store)

    assert Enum.sort_by(groups, &Jason.encode!(Map.get(&1, :facet, %{}))) ==
             Enum.sort_by(expected, &Jason.encode!(Map.get(&1, :facet, %{})))
  end

  test "aggregate_by_agent matches AgentKPI over the in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(run_id: "mem-a", agent: :codex, verdict: :approve),
      ResultStoreContract.log_record(run_id: "mem-b", agent: :codex, verdict: :reject)
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, ledger} = ResultStore.aggregate_by_agent(store)
    assert ledger == AgentKPI.aggregate(records)
  end

  test "aggregate_recovery_facts matches AgentKPI over persisted records", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-recovery-repaired",
        task_id: "42",
        agent: :codex,
        recovery_attempts: 1,
        recovery_outcome: :repaired,
        recovery_repaired: "moved leaked checkout file",
        recovery_token_usage: %Harness.TokenUsage{input: 20, output: 10, total: 30}
      ),
      ResultStoreContract.log_record(
        run_id: "mem-recovery-dead",
        task_id: "43",
        agent: :claude,
        recovery_attempts: 1,
        recovery_outcome: :dead,
        recovery_token_usage: %Harness.TokenUsage{input: 5, output: 5, total: 10}
      )
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, facts} = ResultStore.aggregate_recovery_facts(store)
    assert sort_recovery_runs(facts) == records |> AgentKPI.aggregate_recovery_facts() |> sort_recovery_runs()
  end

  test "aggregate_review_stuck_causes matches AgentKPI over in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-stuck-selection",
        verdict: nil,
        reason:
          {:review_stuck, "No cross-family reviewer adapter available: {:reviewer_unavailable, #{inspect(Claude)}}"},
        reviewer_adapter: nil
      ),
      ResultStoreContract.log_record(
        run_id: "mem-stuck-timeout",
        verdict: nil,
        reason: {:review_stuck, :timed_out},
        reviewer_adapter: Harness.AgentAdapter.Codex
      ),
      ResultStoreContract.log_record(run_id: "mem-approved", verdict: :approve, reason: :approved)
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, causes} = ResultStore.aggregate_review_stuck_causes(store)
    assert causes == AgentKPI.aggregate_review_stuck_causes(records)
  end

  test "repo_enabled false selects ephemeral memory when no explicit override" do
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_result_store = Application.get_env(:harness, :result_store)

    Application.put_env(:harness, :repo_enabled, false)
    Application.delete_env(:harness, :result_store)

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:result_store, prior_result_store)
    end)

    assert {Store, []} = ResultStore.configured()
  end

  test "ephemeral memory does not survive a reset", %{store: store} do
    assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: "gone-after-restart"), store)
    assert {:ok, [_]} = ResultStore.list_run_records(store, run_id: "gone-after-restart")

    assert :ok = Store.reset(elem(store, 1))
    assert {:ok, []} = ResultStore.list_run_records(store, run_id: "gone-after-restart")
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)

  defp sort_recovery_runs(facts) do
    Map.update!(facts, :per_run, &Enum.sort_by(&1, fn row -> row.run_id end))
  end
end
