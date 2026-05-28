defmodule Harness.ResultStore.FileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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
        adapter: Harness.AgentAdapter.Claude,
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
end
