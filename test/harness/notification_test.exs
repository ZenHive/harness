defmodule Harness.NotificationTest do
  @moduledoc """
  The witness dispatcher: fans an `Event` to the configured sinks, no-ops when
  none are configured, and isolates a misbehaving sink so a broken witness can
  never crash a land.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Notification.Sink
  alias Harness.Test.CaptureSink

  setup do
    Application.put_env(:harness, :test_capture_pid, self())

    on_exit(fn ->
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
    end)

    :ok
  end

  defp event(type \\ :landed, outcome \\ "abc123") do
    %Event{type: type, task_id: "42", run_id: "run-x", project: "proj", branch: "harness/run-x", outcome: outcome}
  end

  describe "notify/1 — fan-out" do
    test "delivers the event to every configured sink" do
      Application.put_env(:harness, :notification_sinks, [CaptureSink])

      assert :ok = Notification.notify(event(:landed, "deadbeef"))

      assert_receive {:notify, %Event{type: :landed, outcome: "deadbeef", task_id: "42"}}
    end
  end

  describe "notify/1 — unconfigured witness is a no-op" do
    test "no configured sink fires nothing and returns :ok" do
      assert :ok = Notification.notify(event())
      refute_receive {:notify, _event}, 100
    end

    test "a non-list sink config is treated as no sinks" do
      Application.put_env(:harness, :notification_sinks, :not_a_list)

      assert :ok = Notification.notify(event())
      refute_receive {:notify, _event}, 100
    end
  end

  describe "notify/1 — failure isolation" do
    test "a raising sink is logged and the remaining sinks still fire" do
      Application.put_env(:harness, :notification_sinks, [RaisingSink, CaptureSink])

      log =
        capture_log(fn ->
          assert :ok = Notification.notify(event(:blocked, "cap exhausted"))
        end)

      assert log =~ "RaisingSink failed"
      # The healthy sink after the raising one still received the event.
      assert_receive {:notify, %Event{type: :blocked, outcome: "cap exhausted"}}
    end
  end

  defmodule RaisingSink do
    @moduledoc false
    @behaviour Sink

    @impl Sink
    @spec notify(Event.t()) :: :ok
    def notify(%Event{}), do: raise("sink boom")
  end
end
