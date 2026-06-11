defmodule Harness.ResultStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Harness.AgentKPI
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

  test "aggregate_by_agent matches AgentKPI over the in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(run_id: "mem-a", agent: :codex, verdict: :approve),
      ResultStoreContract.log_record(run_id: "mem-b", agent: :codex, verdict: :reject)
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, ledger} = ResultStore.aggregate_by_agent(store)
    assert ledger == AgentKPI.aggregate(records)
  end

  test "aggregate_review_stuck_causes matches AgentKPI over in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-stuck-selection",
        verdict: nil,
        reason:
          {:review_stuck,
           "No cross-family reviewer adapter available: {:reviewer_unavailable, #{inspect(Harness.AgentAdapter.Claude)}}"},
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
end
