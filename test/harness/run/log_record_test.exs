defmodule Harness.Run.LogRecordTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.TokenUsage

  defp result(fields) do
    struct!(
      %Result{run_id: "run-1", task_id: "8", state: :done, reason: :passed},
      fields
    )
  end

  defp meta do
    [batch_id: "batch-1", agent: :claude, adapter: Claude, duration_ms: 1234]
  end

  describe "from_result/2 token usage" do
    test "carries the result's parsed usage onto the record" do
      usage = %TokenUsage{input: 50, output: 12, cache_read: 900, total: 962}
      record = LogRecord.from_result(result(token_usage: usage), meta())

      assert record.token_usage == usage
    end

    test "defaults to an empty usage when the result carries none" do
      record = LogRecord.from_result(result(token_usage: nil), meta())

      assert record.token_usage == TokenUsage.empty()
      refute TokenUsage.measured?(record.token_usage)
    end
  end
end
