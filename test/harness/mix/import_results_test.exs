defmodule Harness.Mix.ImportResultsTest do
  @moduledoc """
  Integration tests for `mix harness.import_results` (Task 138).
  """
  use Harness.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Harness.AgentAdapter.Claude
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Repo
  alias Harness.ResultStore
  alias Harness.ResultStore.Postgres, as: PostgresStore
  alias Harness.ResultStore.Schema.BatchResult, as: BatchResultSchema
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord

  @moduletag :integration

  setup do
    Repo.delete_all(RunRecordSchema)
    Repo.delete_all(BatchResultSchema)
    root = Path.join(System.tmp_dir!(), "harness_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "runs"))
    File.mkdir_p!(Path.join(root, "batches"))
    {:ok, root: root}
  end

  test "imports fixture runs and batches with matching counts", %{root: root} do
    write_run(root, "run-a")
    write_run(root, "run-b")
    write_batch(root, "batch-1")

    assert capture_io(fn ->
             Mix.Task.reenable("harness.import_results")
             assert :ok = Mix.Task.run("harness.import_results", ["--root", root, "--repo", "Harness.Repo"])
           end) =~ "Imported 2 run(s), 1 batch(es)"

    assert Repo.aggregate(RunRecordSchema, :count) == 2
    assert Repo.aggregate(BatchResultSchema, :count) == 1
  end

  test "re-running import is idempotent", %{root: root} do
    write_run(root, "run-idem")

    for _ <- 1..2 do
      Mix.Task.reenable("harness.import_results")

      assert :ok =
               Mix.Task.run("harness.import_results", ["--root", root, "--repo", "Harness.Repo"])
    end

    assert Repo.aggregate(RunRecordSchema, :count) == 1
    assert {:ok, [row]} = ResultStore.list_run_records({PostgresStore, repo: Repo}, run_id: "run-idem")
    assert row.run_id == "run-idem"
  end

  test "skips corrupt term files, logs, and exits 0", %{root: root} do
    write_run(root, "run-good")
    corrupt = Path.join([root, "runs", "bad.term"])
    File.write!(corrupt, <<0, 1, 2>>)

    log =
      capture_log(fn ->
        Mix.Task.reenable("harness.import_results")

        assert :ok =
                 Mix.Task.run("harness.import_results", ["--root", root, "--repo", "Harness.Repo"])
      end)

    assert log =~ "skipped"
    assert log =~ "bad.term"
    assert Repo.aggregate(RunRecordSchema, :count) == 1
  end

  defp write_run(root, run_id) do
    rec = %LogRecord{
      batch_id: "b",
      run_id: run_id,
      task_id: "t",
      adapter: Claude,
      state: :done,
      reason: :passed,
      duration_ms: 1,
      repair_attempts: 0,
      first_attempt_failed_check_count: 0,
      failure_cause: %{reason: nil, failed_checks: []},
      verdict: :pass
    }

    path = Path.join([root, "runs", Base.url_encode64(run_id, padding: false) <> ".term"])
    File.write!(path, :erlang.term_to_binary(rec))
  end

  defp write_batch(root, batch_id) do
    br = %BatchResult{batch_id: batch_id, total: 0, max_concurrency: 1, results: []}
    path = Path.join([root, "batches", Base.url_encode64(batch_id, padding: false) <> ".term"])
    File.write!(path, :erlang.term_to_binary(br))
  end
end
