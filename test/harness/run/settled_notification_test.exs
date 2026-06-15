defmodule Harness.Run.SettledNotificationTest do
  use Harness.RunCase, async: false

  alias Harness.Dispatch
  alias Harness.Notification.Event
  alias Harness.Run.Result
  alias Harness.Test.CaptureSink

  setup do
    Application.put_env(:harness, :notification_sinks, [CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())

    on_exit(fn ->
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
    end)

    :ok
  end

  describe "settle/2 — :settled witness" do
    test "approved settle fires :settled with outcome matching Dispatch.summarize_result/1" do
      result = run([])

      assert %Result{state: :done, reason: :approved} = result

      assert_receive {:notify, %Event{type: :settled, outcome: outcome} = event}

      assert outcome == Dispatch.summarize_result(result)
      assert event.task_id == to_string(result.task_id)
      assert event.run_id == result.run_id
      assert event.outcome.passed
    end

    test "rejected settle fires :settled with the same summarize projection" do
      result = run(reviewer_adapter_opts: [command: {:review, "reject"}])

      assert %Result{state: :failed} = result

      assert_receive {:notify, %Event{type: :settled, outcome: outcome}}

      assert outcome == Dispatch.summarize_result(result)
      refute outcome.passed
      assert outcome.state == :failed
    end
  end
end
