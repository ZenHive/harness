defmodule Harness.Notification.Sink do
  @moduledoc """
  Behaviour for a merge-train notification sink.

  A sink receives `Harness.Notification.Event` structs fired by the lander and
  does *something read-only with respect to the train* — push a phone alert, write
  a log line, or (a buddhi sink) deliberate and enqueue a fresh verified run.

  ## The one capability a sink is **not** granted

  `notify/1` is handed data, never a merge. There is deliberately no callback that
  lands a branch — a sink that wants to act routes through the train's own
  dispatch/landing path (`Harness.Run.Supervisor` / the serialized landing queue),
  inheriting its serialization + re-verification. This is what keeps a witness —
  human or AI — from silently re-becoming a decision gate by hand-merging a
  tracked branch: the affordance simply does not exist in the type.

  ## Don't block the landing queue

  `Harness.Notification.notify/1` calls each sink **inline in the limit-1 landing
  worker**. A fast sink (shell out, log) is fine. A slow/deliberating sink must
  return `:ok` promptly — hand the event to its own process and decide there —
  rather than blocking the next land on an LLM round-trip. Failures are isolated
  by the dispatcher (logged, never propagated), so a broken sink cannot crash a
  land; it still must not *hang* one.
  """

  alias Harness.Notification.Event

  @doc """
  Handles one merge-train `event`. Must return `:ok` promptly.

  Implementations should not raise; the dispatcher rescues and logs, but a sink
  that swallows its own errors keeps the failure local to its concern.
  """
  @callback notify(Event.t()) :: :ok
end
