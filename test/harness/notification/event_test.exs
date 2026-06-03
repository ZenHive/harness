defmodule Harness.Notification.EventTest do
  @moduledoc """
  `Event.summary/1` — the sakshi (lossy, human-glance) projection. Landed and
  blocked are covered by the moduledoc doctests; this exercises the
  in-run-discernment payload path.
  """
  use ExUnit.Case, async: true

  alias Harness.Notification.Event

  doctest Event

  describe "summary/1 — in_run_discernment" do
    test "names the action and verdict from the sampled payload" do
      event = %Event{
        type: :in_run_discernment,
        task_id: "101",
        outcome: %{action: :halt, verdict: :reject, rationale: "destructive rm -rf outside the worktree"}
      }

      assert Event.summary(event) == "in-run discernment on task 101: halt (reject)"
    end

    test "a notify-only sample summarizes without implying a halt" do
      event = %Event{
        type: :in_run_discernment,
        task_id: "7",
        outcome: %{action: :notify_only, verdict: :unclear, rationale: "grader timed out"}
      }

      assert Event.summary(event) == "in-run discernment on task 7: notify_only (unclear)"
    end
  end
end
