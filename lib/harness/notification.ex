defmodule Harness.Notification do
  @moduledoc """
  Fans a merge-train `Harness.Notification.Event` to the configured sinks.

  The lander (`Harness.Lander.Resilience`) calls `notify/1` when a run lands, a
  task is blocked, or a branch comes back red post-merge. This module is the thin
  dispatcher: read the sink list from app config, hand each the event, isolate
  every sink's failure so a broken sink can never crash a land.

  ## Configuration

      config :harness, :notification_sinks, [Harness.Notification.CommandSink]

  An empty or absent list is a **silent no-op** — the unconfigured-witness
  contract: harness running with no one watching is the default, not an error.

  ## Read-only by construction

  A sink is handed an `Event`; the behaviour grants no way to land a branch (see
  `Harness.Notification.Sink`). A discerning (buddhi) sink that wants to act does
  so *through* the train — it enqueues a fresh verified run — never by hand-merging
  the tracked branch. `Harness.Oban.tracked_landing_branches/1` lets such a witness
  see what the train already owns before it acts.
  """

  alias Harness.Notification.Event

  require Logger

  @doc """
  Delivers `event` to every configured sink, returning `:ok` unconditionally.

  Each sink runs inline; a sink that raises or exits is logged and skipped so the
  remaining sinks — and the landing job that called this — proceed. No configured
  sink is a no-op.
  """
  @spec notify(Event.t()) :: :ok
  def notify(%Event{} = event) do
    Enum.each(sinks(), &deliver(&1, event))
  end

  @spec sinks() :: [module()]
  defp sinks do
    case Application.get_env(:harness, :notification_sinks, []) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  @spec deliver(module(), Event.t()) :: :ok
  defp deliver(sink, event) do
    sink.notify(event)
    :ok
  rescue
    # Bare by design: a sink is caller-registered, arbitrary code with an
    # unbounded exception surface — isolate the witness from any of it.
    error -> log_failure(sink, event, error)
  catch
    kind, value -> log_failure(sink, event, {kind, value})
  end

  @spec log_failure(module(), Event.t(), term()) :: :ok
  defp log_failure(sink, event, error) do
    Logger.error("harness notify: sink #{inspect(sink)} failed on #{Event.summary(event)}: #{inspect(error)}")
    :ok
  end
end
