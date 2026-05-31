defmodule Harness.Test.CaptureSink do
  @moduledoc """
  Test `Harness.Notification.Sink` that forwards each event to a pid.

  Configure the receiver before exercising a notify path:

      Application.put_env(:harness, :notification_sinks, [Harness.Test.CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

  Each `notify/1` sends `{:notify, Harness.Notification.Event.t()}` to that pid, so
  a test can `assert_receive` the fired events. No configured pid is a no-op (the
  message is simply dropped), keeping the sink safe if a stray notify fires.
  """

  @behaviour Harness.Notification.Sink

  alias Harness.Notification.Event

  @impl Harness.Notification.Sink
  @spec notify(Event.t()) :: :ok
  def notify(%Event{} = event) do
    case Application.get_env(:harness, :test_capture_pid) do
      pid when is_pid(pid) -> send(pid, {:notify, event})
      _absent -> :ok
    end

    :ok
  end
end
