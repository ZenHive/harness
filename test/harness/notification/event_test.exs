defmodule Harness.Notification.EventTest do
  @moduledoc """
  `Event.summary/1` — the sakshi (lossy, human-glance) projection. Landed and
  blocked are covered by the moduledoc doctests; this exercises the
  `post_merge_red` Verdict path and its fallbacks.
  """
  use ExUnit.Case, async: true

  alias Harness.Notification.Event
  alias Harness.Verification.Result
  alias Harness.Verification.Verdict

  doctest Event

  defp result(name, status) do
    %Result{name: name, command: "cmd", status: status, kind: :exited, exit_status: 0, output: ""}
  end

  defp red_event(outcome) do
    %Event{type: :post_merge_red, task_id: "101", outcome: outcome}
  end

  describe "summary/1 — post_merge_red" do
    test "names the failing checks from the verdict" do
      verdict = %Verdict{
        status: :fail,
        results: [result("credo", :pass), result("test", :fail), result("dialyzer", :fail)]
      }

      assert Event.summary(red_event(verdict)) == "post-merge red on task 101: failed test, dialyzer"
    end

    test "reports when no failing check is recorded" do
      verdict = %Verdict{status: :fail, results: [result("credo", :pass)]}

      assert Event.summary(red_event(verdict)) == "post-merge red on task 101: no failing check recorded"
    end

    test "falls back to inspect for a non-verdict outcome" do
      assert Event.summary(red_event(:weird)) == "post-merge red on task 101: :weird"
    end
  end
end
