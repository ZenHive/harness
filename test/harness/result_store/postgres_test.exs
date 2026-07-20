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

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Harness.Repo.MigrationGuard
  alias Harness.ResultStore
  alias Harness.ResultStore.DeadLetter
  alias Harness.ResultStore.Postgres, as: Store
  alias Harness.ResultStoreContract

  @moduletag :integration
  @moduletag :tmp_dir

  @review_proposed_tasks_migration 20_260_720_120_000

  defmodule RaisingRepo do
    @moduledoc false
    # Stands in for an unavailable DB: every op raises a connection failure, the
    # kind the narrowed best-effort rescue swallows into {:error, _}.

    @spec insert(Ecto.Changeset.t(), keyword()) :: no_return()
    def insert(_changeset, _opts), do: raise(DBConnection.ConnectionError, "simulated connection loss")
  end

  setup %{tmp_dir: tmp_dir} do
    # Point the facade at the Postgres backend with our test Repo for this test.
    # (test env forces Memory + repo_enabled false by default.)
    prev = Application.get_env(:harness, :result_store)
    prev_dl = Application.get_env(:harness, :result_store_dead_letter)
    prev_repo_enabled = Application.get_env(:harness, :repo_enabled)
    Application.put_env(:harness, :result_store, {Store, repo: Harness.Repo})
    Application.put_env(:harness, :result_store_dead_letter, root: Path.join(tmp_dir, "dead_letter"))
    Application.put_env(:harness, :repo_enabled, true)

    on_exit(fn ->
      Application.put_env(:harness, :result_store, prev)

      if prev_dl,
        do: Application.put_env(:harness, :result_store_dead_letter, prev_dl),
        else: Application.delete_env(:harness, :result_store_dead_letter)

      if is_nil(prev_repo_enabled),
        do: Application.delete_env(:harness, :repo_enabled),
        else: Application.put_env(:harness, :repo_enabled, prev_repo_enabled)
    end)

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

  describe "schema drift — undefined_column spill and replay (Task 370)" do
    setup do
      %{store: {Store, repo: Repo}}
    end

    test "boot migration guard accepts the fully migrated schema" do
      assert :ignore = MigrationGuard.start_link()
    end

    test "pins observed undefined_column semantics against a drifted test schema", %{store: store} do
      # Reproduce the 2026-07-20 class: code references a column the table lacks.
      # Sandbox rolls the DROP back at test end.
      SQL.query!(Repo, "ALTER TABLE run_records DROP COLUMN review_proposed_tasks", [])

      err =
        assert_raise Postgrex.Error, fn ->
          SQL.query!(Repo, "SELECT review_proposed_tasks FROM run_records LIMIT 0", [])
        end

      assert err.postgres.code == :undefined_column
      assert err.postgres.pg_code == "42703"

      record =
        ResultStoreContract.log_record(
          run_id: "run-drift-undefined-col",
          task_id: "370",
          verdict: :approve,
          review_proposed_tasks: [%{"title" => "follow-up"}]
        )

      # Backend surfaces the exact Postgrex code (no raise out of record_run).
      assert {:error, %Postgrex.Error{postgres: %{code: :undefined_column, pg_code: "42703"}}} =
               Store.record_run(record, repo: Repo)

      # Facade spills + logs loudly (operator surface).
      log =
        capture_log(fn ->
          assert {:error, %Postgrex.Error{postgres: %{code: :undefined_column}}} =
                   ResultStore.record_run(record, store)
        end)

      assert log =~ "FAILED to persist run record run-drift-undefined-col"
      assert DeadLetter.exists?("run-drift-undefined-col")

      # Restore the column (schema fixed) and replay — record must recover.
      SQL.query!(Repo, "ALTER TABLE run_records ADD COLUMN review_proposed_tasks jsonb", [])

      assert {:ok, %{replayed: 1, remaining: 0}} = ResultStore.replay_spilled(store)
      refute DeadLetter.exists?("run-drift-undefined-col")

      assert {:ok, [%{run_id: "run-drift-undefined-col", verdict: :approve}]} =
               ResultStore.list_run_records(store, run_id: "run-drift-undefined-col")
    end

    test "mark_landed on a missing row returns not_found without raising", %{store: store} do
      assert {:error, :run_record_not_found} =
               ResultStore.mark_landed("never-inserted-run", "abc123", store)
    end

    test "pending migration warning names an unapplied migration" do
      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [@review_proposed_tasks_migration])

      assert {@review_proposed_tasks_migration, "add_review_proposed_tasks_to_run_records"} in MigrationGuard.pending()

      assert "#{@review_proposed_tasks_migration} add_review_proposed_tasks_to_run_records" in MigrationGuard.pending_labels()
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

  describe "tolerant row decode (Task 365)" do
    test "a real jsonb row referencing an unknown atom is skipped, healthy siblings still return" do
      project = "tolerant-decode-#{System.unique_integer([:positive])}"
      unknown_key = "unknown_atom_key_#{System.unique_integer([:positive])}"

      # Guard the premise: the key must genuinely not be a loaded atom, otherwise
      # the decode would succeed and the test would pass for the wrong reason.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

      store = {Store, repo: Repo}

      for run_id <- ["healthy-1", "poisoned", "healthy-2"] do
        assert :ok =
                 ResultStore.record_run(
                   ResultStoreContract.log_record(run_id: run_id, project_name: project),
                   store
                 )
      end

      # Simulate a row persisted by an older/other BEAM: its jsonb reason carries a
      # key whose atom is not loaded here, so decode_map_key/1 raises ArgumentError.
      SQL.query!(
        Repo,
        "UPDATE run_records SET reason = jsonb_build_object($1::text, 'value') WHERE run_id = $2",
        [unknown_key, "poisoned"]
      )

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, records} = ResultStore.list_run_records(store, project_name: project)

          assert records |> Enum.map(& &1.run_id) |> Enum.sort() == ["healthy-1", "healthy-2"]
        end)

      assert log =~ "skipped 1 undecodable run_records row(s) during list_run_records scan"
    end

    test "a point lookup of the undecodable row degrades to an empty list, never an error tuple" do
      unknown_key = "unknown_atom_key_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

      store = {Store, repo: Repo}

      assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: "poisoned-solo"), store)

      SQL.query!(
        Repo,
        "UPDATE run_records SET reason = jsonb_build_object($1::text, 'value') WHERE run_id = $2",
        [unknown_key, "poisoned-solo"]
      )

      assert {:ok, []} = ResultStore.list_run_records(store, run_id: "poisoned-solo")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
