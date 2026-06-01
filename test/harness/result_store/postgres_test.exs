defmodule Harness.ResultStore.PostgresTest do
  @moduledoc """
  Integration tests for Harness.ResultStore.Postgres (Task 137).

  Tagged :integration: requires a live Postgres with the harness_test DB
  migrated (`MIX_ENV=test mix ecto.create ecto.migrate`).

  Uses Harness.DataCase for sandboxed Repo + shared connection.
  Exercises the exact same contract as the File backend.
  """
  use Harness.DataCase, async: false

  alias Harness.ResultStore
  alias Harness.ResultStore.Postgres, as: Store
  alias Harness.ResultStoreContract

  @moduletag :integration

  setup do
    # Point the facade at the Postgres backend with our test Repo for this test.
    # (test env forces File + repo_enabled false by default.)
    prev = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, {Store, repo: Harness.Repo})

    on_exit(fn -> Application.put_env(:harness, :result_store, prev) end)

    :ok
  end

  describe "ResultStore.Postgres contract" do
    test "passes the shared CRUD contract" do
      assert :ok = ResultStoreContract.assert_crud_roundtrips(ResultStore.configured())
    end

    test "roundtrips complex fields (tuple reason, non-UTF8 binary, nested failure_cause)" do
      assert :ok = ResultStoreContract.assert_complex_fields(ResultStore.configured())
    end
  end

  describe "best-effort contract (never raises)" do
    test "record_run returns {:error, _} when repo is unavailable (no crash)" do
      # Use a deliberately bad repo name that won't be running.
      bad_store = {Store, repo: BadRepoThatDoesNotExist}

      rec = ResultStoreContract.log_record(run_id: "bad-repo-1")

      assert {:error, _} = ResultStore.record_run(rec, bad_store)
    end

    test "save_batch returns {:error, _} when repo is unavailable (no crash)" do
      bad_store = {Store, repo: BadRepoThatDoesNotExist}
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
end
