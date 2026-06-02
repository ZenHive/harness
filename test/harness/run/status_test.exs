defmodule Harness.Run.StatusTest do
  use ExUnit.Case, async: true

  alias Harness.FakeAdapter
  alias Harness.Run.LogRecord
  alias Harness.Run.Status

  describe "from_log_record/1" do
    test "maps a settled red record into a status snapshot" do
      record =
        log_record("run-abc",
          task_id: "42",
          state: :failed,
          reason: {:verification_red, [:credo]},
          verdict: :fail,
          review_iterations: 2,
          agent_outcome_kind: :exited
        )

      status = Status.from_log_record(record)

      assert %Status{} = status
      assert status.run_id == "run-abc"
      assert status.task_id == "42"
      assert status.state == :failed
      # LogRecord.verdict -> Status.verdict_status, agent_outcome_kind -> agent_kind.
      assert status.verdict_status == :fail
      assert status.agent_kind == :exited
      assert status.review_iterations == 2
      assert status.reason == {:verification_red, [:credo]}
      # Not retained on the record — always nil on a reconstructed snapshot.
      assert status.worktree_path == nil
      assert status.agent_os_pid == nil
    end

    test "maps a green record with no agent outcome kind" do
      record = log_record("run-green", state: :done, reason: :passed, verdict: :pass)

      status = Status.from_log_record(record)

      assert status.state == :done
      assert status.verdict_status == :pass
      assert status.agent_kind == nil
    end

    test "maps a legacy :passed state to :done" do
      record = log_record("run-legacy", state: :passed, reason: :passed, verdict: :pass)

      assert Status.from_log_record(record).state == :done
    end

    test "maps a non-terminal state with a green verdict to :done" do
      record = log_record("run-interrupted-green", state: :verifying, reason: :passed, verdict: :pass)

      assert Status.from_log_record(record).state == :done
    end

    test "maps a non-terminal state without a green verdict to :failed" do
      record = log_record("run-interrupted", state: :verifying, reason: nil, verdict: nil)

      assert Status.from_log_record(record).state == :failed
    end
  end

  defp log_record(run_id, opts) do
    reason = Keyword.get(opts, :reason, :passed)

    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      agent: Keyword.get(opts, :agent),
      adapter: FakeAdapter,
      state: Keyword.get(opts, :state, :done),
      reason: reason,
      verdict: Keyword.get(opts, :verdict, :pass),
      duration_ms: 1_000,
      review_iterations: Keyword.get(opts, :review_iterations, 0),
      first_attempt_failed_check_count: 0,
      failure_cause: %{reason: reason, failed_checks: []},
      agent_outcome_kind: Keyword.get(opts, :agent_outcome_kind),
      agent_output: Keyword.get(opts, :agent_output, "")
    }
  end
end
