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

  describe "summary/1 — local_sync_skipped" do
    test "names the manual sync reason" do
      event = %Event{
        type: :local_sync_skipped,
        task_id: "197",
        outcome: "local main behind origin by 1; sync manually"
      }

      assert Event.summary(event) == "local sync skipped for task 197: local main behind origin by 1; sync manually"
    end
  end

  describe "summary/1 — conflict" do
    test "names the retained-branch conflict output" do
      event = %Event{
        type: :conflict,
        task_id: "119",
        outcome: "CONFLICT (content): Merge conflict in CHANGELOG.md"
      }

      assert Event.summary(event) == "conflict landing task 119: CONFLICT (content): Merge conflict in CHANGELOG.md"
    end
  end

  describe "summary/1 — persist_failed (Task 370)" do
    test "names the run, spill path, and pending migrations" do
      event = %Event{
        type: :persist_failed,
        task_id: "370",
        run_id: "run-1784509159980-54c2a6b7",
        outcome: %{
          reason: "postgrex undefined_column: column \"review_proposed_tasks\" does not exist",
          spilled_path: "/tmp/dead_letter/run-1784509159980-54c2a6b7.etf",
          pending_migrations: ["20260720120000 add_review_proposed_tasks_to_run_records"]
        }
      }

      summary = Event.summary(event)
      assert summary =~ "persist failed for run run-1784509159980-54c2a6b7 task 370"
      assert summary =~ "spilled to /tmp/dead_letter/run-1784509159980-54c2a6b7.etf"
      assert summary =~ "pending migrations: 20260720120000 add_review_proposed_tasks_to_run_records"
    end
  end

  describe "summary/1 — settled" do
    test "names the run, task, terminal state, and settle reason" do
      event = %Event{
        type: :settled,
        task_id: "42",
        run_id: "run-1781487644448-abc",
        outcome: %{
          run_id: "run-1781487644448-abc",
          task_id: "42",
          state: :done,
          reason: :approved,
          passed: true
        }
      }

      assert Event.summary(event) ==
               "settled run run-1781487644448-abc task 42: done/approved"
    end

    test "loudly flags approved runs with reviewer-recorded warnings" do
      event = %Event{
        type: :settled,
        task_id: "42",
        run_id: "run-warning",
        outcome: %{
          state: :done,
          reason: :approved,
          review_warning: true
        }
      }

      assert Event.summary(event) == "settled run run-warning task 42: done/approved REVIEW-WARNING"
    end

    test "tuple settle reasons use the tag only" do
      event = %Event{
        type: :settled,
        task_id: "9",
        run_id: "run-fail",
        outcome: %{state: :failed, reason: {:review_rejected, "nothing salvageable"}}
      }

      assert Event.summary(event) == "settled run run-fail task 9: failed/review_rejected"
    end
  end
end
