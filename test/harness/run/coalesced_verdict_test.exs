defmodule Harness.Run.CoalescedVerdictTest do
  @moduledoc """
  The unit-semantics gate for a coalesced run (Task 368).

  A coalesced run carries N roadmap tasks through ONE reviewer verdict, and the
  lander advances every member at the same landing SHA. So an `approve` is only
  honored when the reviewer explicitly accounted for every member in
  `task_outcomes` — otherwise members would land on a verdict that never judged
  them. There is no partial land: the run settles `:done` as a unit or `:failed`
  as a unit.
  """

  use ExUnit.Case, async: true

  alias Harness.Roadmap.Item
  alias Harness.Run.Actions.Reviewing
  alias Harness.Run.Review

  defp data(task_ids) do
    %{
      item: %Item{
        id: List.first(task_ids) || "41",
        title: "coalesced",
        prompt: "do it",
        agent: :codex,
        task_ids: task_ids
      },
      review: nil,
      reason: nil,
      operator_feedback: nil
    }
  end

  defp review(outcomes, verdict \\ :approve) do
    %Review{verdict: verdict, report: "reviewed", task_outcomes: outcomes}
  end

  describe "coalesced approve — every member must be accounted for" do
    test "approves as a unit when the verdict marks every member approved" do
      outcomes = %{"41" => "approved", "42" => "approved"}

      assert {:next_state, :done, settled} =
               Reviewing.settle_review(data(["41", "42"]), {:ok, review(outcomes)})

      assert settled.reason == :approved
      assert settled.review.task_outcomes == outcomes
    end

    test "fails as a unit when a member outcome is missing from the verdict" do
      assert {:next_state, :failed, settled} =
               Reviewing.settle_review(data(["41", "42"]), {:ok, review(%{"41" => "approved"})})

      assert {:review_rejected, _report} = settled.reason
    end

    test "fails as a unit when a member is explicitly rejected" do
      outcomes = %{"41" => "approved", "42" => "rejected"}

      assert {:next_state, :failed, settled} =
               Reviewing.settle_review(data(["41", "42"]), {:ok, review(outcomes)})

      assert {:review_rejected, _report} = settled.reason
    end

    test "fails as a unit when the verdict omits task_outcomes entirely" do
      assert {:next_state, :failed, _settled} =
               Reviewing.settle_review(data(["41", "42"]), {:ok, review(%{})})
    end

    test "an unknown outcome value is not coerced into an approval" do
      outcomes = %{"41" => "approved", "42" => "probably fine"}

      assert {:next_state, :failed, _settled} =
               Reviewing.settle_review(data(["41", "42"]), {:ok, review(outcomes)})
    end
  end

  describe "non-coalesced runs are unaffected" do
    test "a single-task run approves without any task_outcomes" do
      assert {:next_state, :done, settled} =
               Reviewing.settle_review(data([]), {:ok, review(%{})})

      assert settled.reason == :approved
    end

    test "a run whose task_ids holds exactly one id still approves without task_outcomes" do
      assert {:next_state, :done, settled} =
               Reviewing.settle_review(data(["41"]), {:ok, review(%{})})

      assert settled.reason == :approved
    end
  end
end
