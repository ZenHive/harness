defmodule Harness.Run.LogRecordTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Outcome
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.TokenUsage
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict

  defp result(fields) do
    struct!(
      %Result{run_id: "run-1", task_id: "8", state: :done, reason: :passed},
      fields
    )
  end

  defp meta do
    [batch_id: "batch-1", agent: :claude, adapter: Claude, duration_ms: 1234]
  end

  defp check(fields) do
    struct!(
      %CheckResult{name: "c", command: "cmd", status: :fail, kind: :exited, exit_status: 1, output: ""},
      fields
    )
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

  describe "from_result/2 model" do
    test "parses the reported model from the agent's transcript output" do
      outcome = %Outcome{
        run: nil,
        kind: :exited,
        exit_status: 0,
        output: ~s({"type":"system","subtype":"init","model":"claude-opus-4-8"}\n)
      }

      record = LogRecord.from_result(result(agent_outcome: outcome), meta())

      assert record.model == "claude-opus-4-8"
    end

    test "falls back to the requested model when the agent reports none" do
      outcome = %Outcome{run: nil, kind: :exited, exit_status: 0, output: ~s({"type":"turn.completed"}\n)}

      record =
        LogRecord.from_result(
          result(agent_outcome: outcome),
          Keyword.merge(meta(), agent: :codex, requested_model: "gpt-5.4")
        )

      assert record.model == "gpt-5.4"
    end

    test "prefers the reported model over the requested model when both are present" do
      outcome = %Outcome{
        run: nil,
        kind: :exited,
        exit_status: 0,
        output: ~s({"type":"system","subtype":"init","model":"claude-opus-4-8"}\n)
      }

      record =
        LogRecord.from_result(
          result(agent_outcome: outcome),
          Keyword.put(meta(), :requested_model, "claude-opus-4-7")
        )

      assert record.model == "claude-opus-4-8"
    end

    test "is nil when neither the agent nor the dispatch meta names a model" do
      outcome = %Outcome{run: nil, kind: :exited, exit_status: 0, output: ~s({"type":"turn.completed"}\n)}
      record = LogRecord.from_result(result(agent_outcome: outcome), Keyword.put(meta(), :agent, :codex))

      assert record.model == nil
    end
  end

  describe "resolve_model/3" do
    test "reported > requested > nil" do
      transcript = ~s({"type":"system","subtype":"init","model":"claude-opus-4-8"}\n)

      assert LogRecord.resolve_model(:claude, transcript, "claude-opus-4-7") == "claude-opus-4-8"

      assert LogRecord.resolve_model(:codex, ~s({"type":"turn.completed"}\n), "gpt-5.4") ==
               "gpt-5.4"

      assert LogRecord.resolve_model(:codex, ~s({"type":"turn.completed"}\n), nil) == nil
    end
  end

  describe "from_result/2 domains" do
    test "carries normalized domain tags from meta onto the record" do
      record = LogRecord.from_result(result([]), Keyword.put(meta(), :domains, [:oban, :otp, :oban]))

      assert record.domains == [:oban, :otp]
      assert LogRecord.domains(record) == [:oban, :otp]
    end

    test "defaults to an empty domain list when meta omits domains" do
      record = LogRecord.from_result(result([]), meta())

      assert record.domains == []
      assert LogRecord.domains(record) == []
    end
  end

  describe "from_result/2 check_output" do
    test "captures only the failing checks' output, keyed by check name" do
      verdict = %Verdict{
        status: :fail,
        results: [
          check(name: "test", status: :fail, output: "boom"),
          check(name: "credo", status: :pass, exit_status: 0, output: "clean")
        ]
      }

      record = LogRecord.from_result(result(verdict: verdict), meta())

      assert Map.keys(record.check_output) == ["test"]
      assert record.check_output["test"] == %{output: "boom", truncated: false}
    end

    test "tail-truncates output past the cap and flags it, keeping the diagnostic tail" do
      big = String.duplicate("x", 20_000) <> "TAIL_MARKER"
      verdict = %Verdict{status: :fail, results: [check(name: "dialyzer", output: big)]}

      record = LogRecord.from_result(result(verdict: verdict), meta())
      entry = record.check_output["dialyzer"]

      assert entry.truncated
      assert byte_size(entry.output) <= 16_000
      assert String.ends_with?(entry.output, "TAIL_MARKER")
    end

    test "trims a UTF-8 codepoint split by the tail boundary, keeping valid output" do
      # "你" is 3 bytes; 6000 copies = 18_000 bytes. The 16_000-byte tail starts
      # 2_000 bytes in (not a multiple of 3), so the slice begins mid-codepoint —
      # valid_utf8_tail must trim the leading partial byte(s).
      big = String.duplicate("你", 6_000)
      verdict = %Verdict{status: :fail, results: [check(name: "test", output: big)]}

      record = LogRecord.from_result(result(verdict: verdict), meta())
      entry = record.check_output["test"]

      assert entry.truncated
      assert String.valid?(entry.output)
      assert byte_size(entry.output) <= 16_000
    end

    test "is an empty map for a green verdict" do
      verdict = %Verdict{status: :pass, results: [check(name: "test", status: :pass, exit_status: 0, output: "ok")]}

      record = LogRecord.from_result(result(verdict: verdict), meta())

      assert record.check_output == %{}
    end

    test "is an empty map when the result carries no verdict" do
      record = LogRecord.from_result(result(verdict: nil), meta())

      assert record.check_output == %{}
    end
  end
end
