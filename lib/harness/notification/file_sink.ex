defmodule Harness.Notification.FileSink do
  @moduledoc """
  Append-only JSONL witness sink for orchestrator wakeup.

  Each `notify/1` appends one JSON line with `ts`, `type`, ids, `outcome`, and
  `summary`. Unconfigured `:path` is a silent no-op. See
  [`docs/orchestrator-push-sink-design.md`](../../docs/orchestrator-push-sink-design.md)
  for the push/pull hybrid driver pattern.

  ## Configuration

      config :harness, Harness.Notification.FileSink,
        path: Path.expand("~/.harness/settled.jsonl")
  """

  @behaviour Harness.Notification.Sink

  alias Harness.Notification.Event

  require Logger

  @impl Harness.Notification.Sink
  @spec notify(Event.t()) :: :ok
  def notify(%Event{} = event) do
    case path_config() do
      nil -> :ok
      path -> append(path, envelope(event))
    end
  end

  @spec path_config() :: String.t() | nil
  defp path_config do
    case Application.get_env(:harness, __MODULE__, []) do
      config when is_list(config) ->
        case Keyword.get(config, :path) do
          path when is_binary(path) and path != "" -> path
          _absent -> nil
        end

      _other ->
        nil
    end
  end

  @spec envelope(Event.t()) :: map()
  defp envelope(%Event{} = event) do
    %{
      ts: DateTime.to_iso8601(DateTime.utc_now()),
      type: event.type,
      task_id: event.task_id,
      run_id: event.run_id,
      project: event.project,
      branch: event.branch,
      land_attempt: event.land_attempt,
      outcome: event.outcome,
      summary: Event.summary(event)
    }
  end

  @spec append(String.t(), map()) :: :ok
  defp append(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map) <> "\n", [:append])
    :ok
  rescue
    error ->
      Logger.error("harness notify: FileSink append failed: #{inspect(error)}")
      :ok
  end
end
