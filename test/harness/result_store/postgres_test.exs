defmodule Harness.ResultStore.PostgresTest do
  @moduledoc """
  Integration tests for Harness.ResultStore.Postgres (Task 137).

  Tagged :integration: requires a live Postgres with the harness_test DB
  migrated (`MIX_ENV=test mix ecto.create ecto.migrate`).

  Uses Harness.DataCase for sandboxed Repo + shared connection.
  Exercises the exact same contract as the ephemeral memory backend.
  """
  # async: false because DataCase uses SQL Sandbox shared mode and :result_store env.
  use Harness.DataCase, async: false

  alias Harness.ResultStore
  alias Harness.ResultStore.Postgres, as: Store
  alias Harness.ResultStoreContract

  @moduletag :integration

  defmodule RaisingRepo do
    @moduledoc false
    # Stands in for an unavailable DB: every op raises a connection failure, the
    # kind the narrowed best-effort rescue swallows into {:error, _}.

    @spec insert(Ecto.Changeset.t(), keyword()) :: no_return()
    def insert(_changeset, _opts), do: raise(DBConnection.ConnectionError, "simulated connection loss")
  end

  setup do
    # Point the facade at the Postgres backend with our test Repo for this test.
    # (test env forces Memory + repo_enabled false by default.)
    prev = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, {Store, repo: Harness.Repo})

    on_exit(fn -> Application.put_env(:harness, :result_store, prev) end)

    :ok
  end

  describe "ResultStore.Postgres contract" do
    test "passes the shared CRUD contract" do
      assert :ok = ResultStoreContract.assert_crud_roundtrips(ResultStore.configured())
    end

    test "roundtrips complex fields (tuple reason, non-UTF8 binary, review artifact fields)" do
      assert :ok = ResultStoreContract.assert_complex_fields(ResultStore.configured())
    end

    test "delete_run removes one record idempotently via contract" do
      assert :ok = ResultStoreContract.assert_delete_run(ResultStore.configured())
    end

    test "same-run_id upsert preserves settled evidence via contract" do
      assert :ok = ResultStoreContract.assert_same_run_id_upsert_preserves_settled_evidence(ResultStore.configured())
    end

    test "task_id and landed_sha filters scope results via contract" do
      assert :ok = ResultStoreContract.assert_scoped_filters(ResultStore.configured())
    end
  end

  describe "best-effort contract (never raises)" do
    test "record_run returns {:error, _} when the repo connection fails (no crash)" do
      bad_store = {Store, repo: RaisingRepo}

      rec = ResultStoreContract.log_record(run_id: "bad-repo-1")

      assert {:error, _} = ResultStore.record_run(rec, bad_store)
    end

    test "save_batch returns {:error, _} when the repo connection fails (no crash)" do
      bad_store = {Store, repo: RaisingRepo}
      br = %Harness.Batch.Result{batch_id: "bad-b", total: 0, max_concurrency: 1, results: []}

      assert {:error, _} = ResultStore.save_batch(br, bad_store)
    end
  end

  describe "configured/0 respects explicit override" do
    test "explicit :result_store wins even if repo_enabled would suggest otherwise" do
      # Already set in this test's setup to Postgres; verify facade sees it.
      assert {Store, _} = ResultStore.configured()
    end
  end

  describe "repo_enabled selection" do
    test "repo_enabled true selects Postgres and records survive a facade reload" do
      prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
      prior_result_store = Application.get_env(:harness, :result_store)

      Application.put_env(:harness, :repo_enabled, true)
      Application.delete_env(:harness, :result_store)

      on_exit(fn ->
        restore(:repo_enabled, prior_repo_enabled)
        restore(:result_store, prior_result_store)
      end)

      assert {Store, []} = ResultStore.configured()

      record = ResultStoreContract.log_record(run_id: "pg-survives-reload", verdict: :approve)
      assert :ok = ResultStore.record_run(record, {Store, repo: Repo})

      assert {:ok, [%{run_id: "pg-survives-reload"}]} =
               ResultStore.list_run_records({Store, repo: Repo}, run_id: "pg-survives-reload")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
