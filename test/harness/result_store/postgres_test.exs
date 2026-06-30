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

  alias Harness.AgentAdapter.Claude
  alias Harness.ResultStore
  alias Harness.ResultStore.Postgres, as: Store
  alias Harness.ResultStoreContract
  alias Harness.TokenUsage

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
  end

  describe "same-run_id upsert never loses settled evidence (Task 163)" do
    test "a later write with missing data keeps the rich fields and updates bookkeeping" do
      store = ResultStore.configured()

      rich =
        ResultStoreContract.log_record(
          run_id: "r-upsert",
          state: :failed,
          reason: {:review_rejected, "not salvageable"},
          duration_ms: 4321,
          verdict: :reject,
          agent_output: "rich transcript",
          agent_outcome_kind: :exited,
          agent_diff_size: 12,
          reviewer_diff_size: 30,
          review_iterations: 1,
          reviewer_reprompt_count: 1,
          reviewer_rotation_count: 2,
          reviewer_adapter: Claude,
          review_report: "not salvageable",
          review_ratings: %{"code_quality" => 2},
          reviewer_outcome_kind: :exited,
          reviewer_exit_status: 0,
          reviewer_output: "reviewer transcript: checks pass, no verdict written",
          recovery_attempts: 1,
          recovery_outcome: :dead,
          recovery_repaired: "documented unrecoverable checkout leak",
          recovery_token_usage: %TokenUsage{input: 20, output: 10, total: 30}
        )

      assert :ok = ResultStore.record_run(rich, store)

      # Re-record the same run_id with the empty defaults a retry/no-op attempt
      # produces: nil verdict, empty output, zero iterations, no reviewer.
      sparse =
        ResultStoreContract.log_record(
          run_id: "r-upsert",
          state: :done,
          reason: :approved,
          duration_ms: 5,
          verdict: nil,
          review_ratings: %{}
        )

      assert :ok = ResultStore.record_run(sparse, store)

      assert {:ok, [rec]} = ResultStore.list_run_records(store, run_id: "r-upsert")

      # bookkeeping: the latest write wins
      assert rec.state == :done
      assert rec.reason == :approved
      assert rec.duration_ms == 5

      # rich evidence: the settled attempt's data survives the sparse write
      assert rec.verdict == :reject
      assert rec.agent_output == "rich transcript"
      assert rec.agent_outcome_kind == :exited
      assert rec.agent_diff_size == 12
      assert rec.reviewer_diff_size == 30
      assert rec.review_iterations == 1
      assert rec.reviewer_reprompt_count == 1
      assert rec.reviewer_rotation_count == 2
      assert rec.reviewer_adapter == Claude
      assert rec.review_report == "not salvageable"
      assert rec.review_ratings == %{"code_quality" => 2}
      assert rec.reviewer_outcome_kind == :exited
      assert rec.reviewer_exit_status == 0
      assert rec.reviewer_output == "reviewer transcript: checks pass, no verdict written"
      assert rec.recovery_attempts == 1
      assert rec.recovery_outcome == :dead
      assert rec.recovery_repaired == "documented unrecoverable checkout leak"
      assert rec.recovery_token_usage == %TokenUsage{input: 20, output: 10, total: 30}
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
