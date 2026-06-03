defmodule Harness.Run.StatusTest do
  use ExUnit.Case, async: true

  alias Harness.FakeAdapter
  alias Harness.Run.LogRecord
  alias Harness.Run.Status

  describe "from_log_record/1" do
    test "maps a settled rejected record into a status snapshot" do
      record =
        log_record("run-abc",
          task_id: "42",
          state: :failed,
          reason: {:review_rejected, "off-task work, nothing to salvage"},
          verdict: :reject,
          agent_outcome_kind: :exited
        )

      status = Status.from_log_record(record)

      assert %Status{} = status
      assert status.run_id == "run-abc"
      assert status.task_id == "42"
      assert status.state == :failed
      # LogRecord.verdict -> Status.review_verdict, agent_outcome_kind -> agent_kind.
      assert status.review_verdict == :reject
      assert status.agent_kind == :exited
      assert status.reason == {:review_rejected, "off-task work, nothing to salvage"}
      # Not retained on the record — always nil on a reconstructed snapshot.
      assert status.worktree_path == nil
      assert status.agent_os_pid == nil
    end

    test "maps an approved record with no agent outcome kind" do
      record = log_record("run-green", state: :done, reason: :approved, verdict: :approve)

      status = Status.from_log_record(record)

      assert status.state == :done
      assert status.review_verdict == :approve
      assert status.agent_kind == nil
    end

    test "maps a record that never reached review with a nil verdict" do
      record = log_record("run-cancelled", state: :failed, reason: :cancelled, verdict: nil)

      status = Status.from_log_record(record)

      assert status.state == :failed
      assert status.review_verdict == nil
    end

    test "maps a non-terminal persisted state to :failed" do
      # A record persisted mid-flight (e.g. BEAM death during :reviewing) is
      # not a settled run — it classifies as :failed, never silently :done.
      record = log_record("run-interrupted", state: :reviewing, reason: nil, verdict: nil)

      assert Status.from_log_record(record).state == :failed
    end
  end

  defp log_record(run_id, opts) do
    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      agent: Keyword.get(opts, :agent),
      adapter: FakeAdapter,
      state: Keyword.get(opts, :state, :done),
      reason: Keyword.get(opts, :reason, :approved),
      verdict: Keyword.get(opts, :verdict, :approve),
      duration_ms: 1_000,
      agent_outcome_kind: Keyword.get(opts, :agent_outcome_kind),
      agent_output: Keyword.get(opts, :agent_output, "")
    }
  end
end
