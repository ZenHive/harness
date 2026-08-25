defmodule Harness.Run.ReviewFenceTest do
  @moduledoc """
  Task 393: the verdict artifact is fenced to the reviewer invocation that
  wrote it. A killed reviewer's stale approve must not settle the run, and a
  truncated implementer transcript must say so.
  """

  use Harness.RunCase, async: true

  alias Harness.Run.Actions.Reviewing

  @tail_bytes 40_000

  describe "stale-approve fence" do
    test "a killed reviewer's approve is not settled after a silent rotator" do
      result =
        run(
          reviewer: [WriteApproveThenIdleReviewer, FakeAdapter],
          reviewer_adapter_opts: [command: :echo],
          reviewing_idle_timeout: 1_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ Review.artifact_path()
      refute result.reason == :approved
      assert result.reviewer_rotation_count == 1
    end

    test "an attempt-identity mismatch re-prompts once, then settles on the bound retry" do
      result =
        run(
          reviewer: MismatchThenBindReviewer,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :done, reason: :approved, reviewer_reprompt_count: 1} = result
      assert %Review{verdict: :approve} = result.review
    end
  end

  describe "transcript_tail/1 truncation marker" do
    test "does not mark a transcript that fits in the tail" do
      transcript = String.duplicate("a", @tail_bytes)

      assert Reviewing.transcript_tail(transcript) == transcript
      refute Reviewing.transcript_tail(transcript) =~ "elided"
    end

    test "states elided and total bytes only when the transcript exceeded the tail" do
      transcript = String.duplicate("a", @tail_bytes + 7)
      tail = Reviewing.transcript_tail(transcript)

      assert tail =~ "7 bytes elided of #{@tail_bytes + 7} total"
      assert tail =~ "transcript truncated"
      assert String.ends_with?(tail, String.duplicate("a", @tail_bytes))
    end
  end
end
