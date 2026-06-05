defmodule Harness.Run.LogRecordTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Outcome
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Review
  alias Harness.TokenUsage

  defp result(fields) do
    struct!(
      %Result{run_id: "run-1", task_id: "8", state: :done, reason: :approved},
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

    test "an unmeasured result carries an empty usage onto the record" do
      # A %Result{} always holds a %TokenUsage{} (struct default — never nil);
      # unmeasured runs carry the empty usage through to the record.
      record = LogRecord.from_result(result([]), meta())

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

  describe "from_result/2 review (the reviewer's verdict artifact)" do
    test "carries the reviewer's verdict, report, and ratings onto the record" do
      review = %Review{
        verdict: :approve,
        report: "ran the checks, fixed a credo nit, approving",
        ratings: %{"performance" => 8, "code_quality" => 7}
      }

      record = LogRecord.from_result(result(review: review), meta())

      assert record.verdict == :approve
      assert record.review_report == "ran the checks, fixed a credo nit, approving"
      assert record.review_ratings == %{"performance" => 8, "code_quality" => 7}
    end

    test "carries a rejection verdict with the reviewer's report" do
      review = %Review{verdict: :reject, report: "nothing to salvage"}

      record =
        LogRecord.from_result(
          result(state: :failed, reason: {:review_rejected, "nothing to salvage"}, review: review),
          meta()
        )

      assert record.verdict == :reject
      assert record.review_report == "nothing to salvage"
      assert record.review_ratings == %{}
    end

    test "leaves the verdict fields at their defaults when the run never produced a review" do
      record = LogRecord.from_result(result(state: :failed, reason: :cancelled, review: nil), meta())

      assert record.verdict == nil
      assert record.review_report == nil
      assert record.review_ratings == %{}
    end
  end

  describe "from_result/2 reviewer outcome (raw transcript + kind/exit_status)" do
    test "carries the reviewer's kind, exit status, and raw transcript onto the record" do
      outcome = %Outcome{
        run: nil,
        kind: :exited,
        exit_status: 0,
        output: ~s({"type":"system"}\n{"type":"result","subtype":"success"}\n)
      }

      record = LogRecord.from_result(result(reviewer_outcome: outcome), meta())

      assert record.reviewer_outcome_kind == :exited
      assert record.reviewer_exit_status == 0
      assert record.reviewer_output == ~s({"type":"system"}\n{"type":"result","subtype":"success"}\n)
    end

    test "leaves the reviewer fields at their defaults when there is no clean reviewer outcome" do
      # Killed reviewer (idle/spawn timeout, crash) or no reviewer available:
      # reviewer_outcome is nil, so the persisted facts stay at their defaults
      # rather than being fabricated.
      record = LogRecord.from_result(result(state: :failed, reason: :cancelled, reviewer_outcome: nil), meta())

      assert record.reviewer_outcome_kind == nil
      assert record.reviewer_exit_status == nil
      assert record.reviewer_output == ""
    end

    test "a review_stuck run persists the reviewer's raw transcript so the next stuck run is diagnosable" do
      # The dominant review_stuck mode: the reviewer exits cleanly but writes no
      # .harness/review.json. The Outcome IS present (kind=:exited, status 0);
      # its transcript is the only record of what the reviewer did before
      # omitting the verdict file.
      transcript =
        ~s({"type":"assistant","text":"checks pass, looks good"}\n) <>
          ~s({"type":"result","subtype":"success"}\n)

      outcome = %Outcome{run: nil, kind: :exited, exit_status: 0, output: transcript}

      record =
        LogRecord.from_result(
          result(
            state: :failed,
            reason: {:review_stuck, "Reviewer wrote no .harness/review.json verdict artifact."},
            reviewer_outcome: outcome,
            review: nil
          ),
          meta()
        )

      # The run failed with no verdict — but the reviewer's transcript survives.
      assert record.verdict == nil
      assert record.reviewer_outcome_kind == :exited
      assert record.reviewer_exit_status == 0
      assert record.reviewer_output == transcript

      case record.reason do
        {:review_stuck, _report} -> :ok
        other -> flunk("expected a {:review_stuck, _} reason, got: #{inspect(other)}")
      end
    end
  end

  describe "from_result/2 review_iterations (derived from the reviewer's diff)" do
    test "is 0 when the reviewer changed nothing (first-attempt pass)" do
      record = LogRecord.from_result(result(reviewer_diff_size: 0), meta())

      assert record.review_iterations == 0
      assert record.reviewer_diff_size == 0
    end

    test "is 1 when the reviewer committed fixes" do
      record = LogRecord.from_result(result(reviewer_diff_size: 12), meta())

      assert record.review_iterations == 1
      assert record.reviewer_diff_size == 12
    end

    test "is 0 when the run never reached review" do
      record = LogRecord.from_result(result(reviewer_diff_size: nil), meta())

      assert record.review_iterations == 0
      assert record.reviewer_diff_size == nil
    end
  end
end
