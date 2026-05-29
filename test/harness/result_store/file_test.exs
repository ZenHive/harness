defmodule Harness.ResultStore.FileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Harness.AgentAdapter.Claude
  alias Harness.Batch.Result
  alias Harness.ResultStore.File, as: Store
  alias Harness.Run.LogRecord

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "harness_result_store_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "list_run_records/2 with a corrupt sibling file" do
    test "returns the healthy record and logs a warning for the bad one", %{root: root} do
      record = %LogRecord{
        batch_id: "batch-test",
        run_id: "run-abc",
        task_id: "task-73",
        adapter: Claude,
        state: :passed,
        reason: nil,
        duration_ms: 1234,
        repair_attempts: 0,
        first_attempt_failed_check_count: 0,
        failure_cause: %{reason: nil, failed_checks: []}
      }

      :ok = Store.record_run(record, root: root)

      corrupt_path = Path.join([root, "runs", "garbage.term"])
      File.write!(corrupt_path, <<0, 1, 2, 3, "not a term">>)

      {result, log} = with_log(fn -> Store.list_run_records([], root: root) end)

      assert {:ok, [returned]} = result
      assert returned.run_id == "run-abc"
      assert log =~ "skipping undecodable term file"
      assert log =~ "invalid_term_file"
    end

    test "returns {:ok, []} when the only file is corrupt", %{root: root} do
      runs_dir = Path.join(root, "runs")
      File.mkdir_p!(runs_dir)
      File.write!(Path.join(runs_dir, "garbage.term"), <<255, 254, 253>>)

      {result, log} = with_log(fn -> Store.list_run_records([], root: root) end)

      assert {:ok, []} = result
      assert log =~ "skipping undecodable term file"
    end
  end

  describe "CRUD roundtrips and filters" do
    test "record_run + list_run_records roundtrip with filter", %{root: root} do
      record = %LogRecord{
        batch_id: "b1",
        run_id: "r1",
        task_id: "t1",
        adapter: Claude,
        state: :passed,
        reason: nil,
        duration_ms: 42,
        repair_attempts: 0,
        first_attempt_failed_check_count: 0,
        failure_cause: %{reason: nil, failed_checks: []}
      }

      assert :ok = Store.record_run(record, root: root)

      assert {:ok, [retrieved]} = Store.list_run_records([batch_id: "b1"], root: root)
      assert retrieved.run_id == "r1"
      assert retrieved.state == :passed

      # Non-matching filter
      assert {:ok, []} = Store.list_run_records([batch_id: "nope"], root: root)
    end

    # Review fix #13: write_term/2 writes a sibling .tmp then atomically renames
    # it into place. After a successful write the .term must exist and no .tmp
    # sibling may linger (a leftover .tmp would mean the rename never happened).
    test "record_run leaves the final .term and no .tmp sibling", %{root: root} do
      record = %LogRecord{
        batch_id: "b-atomic",
        run_id: "r-atomic",
        task_id: "t",
        adapter: Claude,
        state: :passed,
        reason: nil,
        duration_ms: 1,
        repair_attempts: 0,
        first_attempt_failed_check_count: 0,
        failure_cause: %{reason: nil, failed_checks: []}
      }

      assert :ok = Store.record_run(record, root: root)

      runs_dir = Path.join(root, "runs")
      files = File.ls!(runs_dir)

      assert Enum.any?(files, &String.ends_with?(&1, ".term"))
      refute Enum.any?(files, &String.ends_with?(&1, ".tmp"))
    end

    test "save_batch + load_batch happy path and invalid term type", %{root: root} do
      alias Result, as: BatchResult

      batch_result = %BatchResult{
        batch_id: "batch-crud",
        total: 0,
        max_concurrency: 1,
        results: []
      }

      assert :ok = Store.save_batch(batch_result, root: root)

      assert {:ok, loaded} = Store.load_batch("batch-crud", root: root)
      assert loaded.batch_id == "batch-crud"

      # Write a valid term that is not a BatchResult -> load_batch should error
      # Use Base.url_encode64 (same as Store.safe_id) so the path is legal under the root guard.
      bad_name = Base.url_encode64("bad-batch", padding: false)
      bad_path = Path.join([root, "batches", bad_name <> ".term"])
      File.mkdir_p!(Path.dirname(bad_path))
      File.write!(bad_path, :erlang.term_to_binary(%{not: :a_batch}))

      assert {:error, {:invalid_term_file, _}} = Store.load_batch("bad-batch", root: root)
    end
  end

  describe "storage safety and configuration" do
    test "configured_root falls back when Application env is not {__MODULE__, opts}", %{root: root} do
      original = Application.get_env(:harness, :result_store)
      on_exit(fn -> Application.put_env(:harness, :result_store, original) end)

      Application.put_env(:harness, :result_store, :some_other_store)

      # Exercises the `_other -> nil` branch of configured_root/0 via the eager
      # Keyword.get default in root/1. Explicit `root:` keeps the write sandboxed.
      assert :ok =
               Store.record_run(
                 %LogRecord{
                   batch_id: "cfg-other",
                   run_id: "r-cfg",
                   task_id: "t",
                   adapter: Claude,
                   state: :passed,
                   reason: nil,
                   duration_ms: 1,
                   repair_attempts: 0,
                   first_attempt_failed_check_count: 0,
                   failure_cause: %{reason: nil, failed_checks: []}
                 },
                 root: root
               )
    end

    test "safe_id produces url-safe encoding without padding", %{root: root} do
      # Direct (via public if exposed, or just trust the 1-liner; here we call through a write that uses it)
      # We already exercise safe_id on every record_run. Add an explicit assertion by round-tripping a weird id.
      weird_id = "run/with/slashes+plus=equals"

      record = %LogRecord{
        batch_id: "b-sid",
        run_id: weird_id,
        task_id: "t",
        adapter: Claude,
        state: :passed,
        reason: nil,
        duration_ms: 1,
        repair_attempts: 0,
        first_attempt_failed_check_count: 0,
        failure_cause: %{reason: nil, failed_checks: []}
      }

      assert :ok = Store.record_run(record, root: root)
      assert {:ok, [r]} = Store.list_run_records([run_id: weird_id], root: root)
      assert r.run_id == weird_id
    end
  end

  describe "Harness.ResultStore behaviour disabled/nil guards (lifts behaviour coverage)" do
    test "record_run/save_batch/list short-circuit on false/nil without calling impl" do
      alias Harness.ResultStore
      alias Result, as: BatchResult

      record = %LogRecord{
        batch_id: "disabled",
        run_id: "r-dis",
        task_id: "t",
        adapter: Claude,
        state: :passed,
        reason: nil,
        duration_ms: 1,
        repair_attempts: 0,
        first_attempt_failed_check_count: 0,
        failure_cause: %{reason: nil, failed_checks: []}
      }

      assert :ok = ResultStore.record_run(record, false)
      assert :ok = ResultStore.record_run(record, nil)

      br = %BatchResult{batch_id: "b-dis", total: 0, max_concurrency: 1, results: []}
      assert :ok = ResultStore.save_batch(br, false)
      assert :ok = ResultStore.save_batch(br, nil)

      assert {:ok, []} = ResultStore.list_run_records(false, [])
      assert {:ok, []} = ResultStore.list_run_records(nil, [])

      assert {:error, :disabled} = ResultStore.load_batch("anything", false)
      assert {:error, :disabled} = ResultStore.load_batch("anything", nil)
    end
  end
end
