defmodule Harness.Notification.CommandSink do
  @moduledoc """
  Built-in notification sink that runs an operator-configured command per event.

  The one shipped `Harness.Notification.Sink` — a *sakshi* (passive-witness) sink:
  it flattens each `Harness.Notification.Event` into environment variables and
  execs a command the operator supplies, covering ntfy / desktop-notify / Slack /
  a curl webhook without harness knowing which. The event fields arrive as:

    * `HARNESS_NOTIFY_TYPE` — `landed` | `blocked` | `in_run_discernment`
    * `HARNESS_NOTIFY_TASK_ID`, `HARNESS_NOTIFY_RUN_ID`
    * `HARNESS_NOTIFY_PROJECT`, `HARNESS_NOTIFY_BRANCH`
    * `HARNESS_NOTIFY_LAND_ATTEMPT`
    * `HARNESS_NOTIFY_SUMMARY` — the one-line `Event.summary/1`

  ## Configuration

      config :harness, Harness.Notification.CommandSink,
        command: "/usr/local/bin/notify-train.sh",
        args: ["--urgent"]

  No `:command` configured ⇒ a silent no-op (the unconfigured-sink contract). The
  command is run with an argv list (never a shell string), so event values cannot
  inject; `command`/`args` come from app config (operator-controlled), not from
  any event payload.
  """

  @behaviour Harness.Notification.Sink

  alias Harness.Notification.Event

  require Logger

  @impl Harness.Notification.Sink
  @spec notify(Event.t()) :: :ok
  def notify(%Event{} = event) do
    case command_config() do
      {command, args} -> run(command, args, event)
      :none -> :ok
    end
  end

  # The operator's command + extra args, or :none when unconfigured.
  @spec command_config() :: {String.t(), [String.t()]} | :none
  defp command_config do
    config = Application.get_env(:harness, __MODULE__, [])

    case Keyword.get(config, :command) do
      command when is_binary(command) -> {command, Keyword.get(config, :args, [])}
      _absent -> :none
    end
  end

  # sobelow_skip ["CI.System"]
  # command/args are operator config (not event-derived), run as an argv list with
  # no shell — event values reach the command only as env vars, so no injection.
  @spec run(String.t(), [String.t()], Event.t()) :: :ok
  defp run(command, args, event) do
    System.cmd(command, args, env: env(event), stderr_to_stdout: true)
    :ok
  rescue
    error ->
      Logger.error("harness notify: command sink #{inspect(command)} raised: #{inspect(error)}")
      :ok
  end

  @spec env(Event.t()) :: [{String.t(), String.t()}]
  defp env(%Event{} = event) do
    [
      {"HARNESS_NOTIFY_TYPE", to_string(event.type)},
      {"HARNESS_NOTIFY_TASK_ID", to_value(event.task_id)},
      {"HARNESS_NOTIFY_RUN_ID", to_value(event.run_id)},
      {"HARNESS_NOTIFY_PROJECT", to_value(event.project)},
      {"HARNESS_NOTIFY_BRANCH", to_value(event.branch)},
      {"HARNESS_NOTIFY_LAND_ATTEMPT", to_string(event.land_attempt)},
      {"HARNESS_NOTIFY_SUMMARY", Event.summary(event)}
    ]
  end

  @spec to_value(String.t() | nil) :: String.t()
  defp to_value(nil), do: ""
  defp to_value(value) when is_binary(value), do: value
end
