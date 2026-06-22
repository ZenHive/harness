defmodule Harness.Dashboard.OpsFeed do
  @moduledoc """
  Fleet-wide PubSub for the dashboard's **audit + lander** lifecycle panel.

  Sibling to `Harness.Dashboard.RunFeed`. Where `RunFeed` carries the
  implementer/reviewer/recovery STAGES of a run (driven by the `Harness.Run`
  gen_statem), this feed carries the two pipeline stages that run as **separate
  Oban workers** and never reach the run gen_statem:

    * **Audit** (`Harness.Audit`) — the post-merge third-family agent run.
    * **Landing** (`Harness.Lander` / `Harness.Lander.Resilience`) — rebase /
      ff-push / conflict→resolver / blocked-by-cap.

  Both broadcast `Harness.Dashboard.OpsFeed.Op` events on the single `harness:ops`
  topic, so one dashboard subscription drives a dedicated ops panel without
  polling. Subscribers receive `{:harness_op, %Op{}}`.

  These events use a **distinct topic and struct** from `RunFeed` on purpose
  (acceptance of task 243): audit/land ops must not masquerade as
  `%Harness.Run.Status{}` rows, so the Active/History run tables stay run-only.

  ## PubSub guard

  Broadcast and subscribe are guarded by `Process.whereis(Harness.PubSub)`, so a
  consumer that skipped the dashboard subtree never crashes on a missing bus —
  mirrors `RunFeed` and `Harness.Dashboard.Transcript`.
  """

  alias Harness.Dashboard.Feed
  alias Harness.Dashboard.OpsFeed.Op

  @pubsub Harness.PubSub
  @topic "harness:ops"

  # The auditor is a real agent run; its raw transcript can be large. The ops
  # panel only needs enough tail to glance at, so cap the broadcast/render
  # payload (mechanical truncation — keeps the LiveView assign bounded).
  @transcript_cap 16_000

  @doc "The fleet-wide audit/land ops PubSub topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to the ops feed. No-op if PubSub is not running."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Feed.subscribe(@pubsub, @topic)

  @doc "Stops the calling process from receiving ops events."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: Feed.unsubscribe(@pubsub, @topic)

  @doc """
  Broadcasts an `Op` event, stamping its `id` and `at`.

  Subscribers receive `{:harness_op, op}`. Silent no-op when PubSub is not running.
  The auditor transcript is capped to the last #{@transcript_cap} bytes so a large
  agent run never balloons the dashboard assign.
  """
  @spec broadcast(Op.t()) :: :ok
  def broadcast(%Op{} = op) do
    stamped = %{op | id: op.id || gen_id(op.kind), at: op.at || DateTime.utc_now(), transcript: cap(op.transcript)}

    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:harness_op, stamped})
    end

    :ok
  end

  @spec gen_id(Op.kind()) :: String.t()
  defp gen_id(kind), do: "#{kind}-#{System.unique_integer([:positive, :monotonic])}"

  @spec cap(String.t() | nil) :: String.t() | nil
  defp cap(nil), do: nil
  defp cap(text) when byte_size(text) <= @transcript_cap, do: text

  # Keep the last @transcript_cap bytes, then drop any leading bytes that form a
  # split multi-byte UTF-8 codepoint: the tail slice can begin mid-codepoint, and
  # a raw `binary_part/3` byte slice would yield an invalid binary that LiveView
  # refuses to render (crashing the ops panel). Mirrors chat_live.ex's
  # `trim_to_valid_utf8`; a codepoint is ≤4 bytes, so the trim drops at most 3.
  defp cap(text) do
    text
    |> binary_part(byte_size(text) - @transcript_cap, @transcript_cap)
    |> trim_leading_to_valid_utf8()
  end

  @spec trim_leading_to_valid_utf8(binary()) :: binary()
  defp trim_leading_to_valid_utf8(bin) do
    cond do
      String.valid?(bin) -> bin
      byte_size(bin) == 0 -> bin
      true -> trim_leading_to_valid_utf8(binary_part(bin, 1, byte_size(bin) - 1))
    end
  end
end
