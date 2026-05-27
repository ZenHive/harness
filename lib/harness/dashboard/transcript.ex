defmodule Harness.Dashboard.Transcript do
  @moduledoc """
  PubSub topic for the live stream-json transcript pane (Task 50, Pass 2).

  The agent's port output passes through `Harness.AgentAdapter.Driver.loop/6`
  one chunk at a time. The run-wrapping `Harness.Run` gen_statem hands the
  driver an `:on_output` callback that calls `broadcast/2` with the
  *harness* run id (the AgentAdapter.Run handle has no run_id of its own —
  see `Harness.AgentAdapter.Run` — so the callback closure carries it).

  Topic shape: `harness:run:<run_id>:transcript`. Subscribers receive
  `{:harness_transcript, run_id, data}` where `data` is the iodata chunk the
  agent emitted.

  Broadcast is guarded by `Process.whereis(Harness.PubSub)` so the driver does
  not crash in environments where `Phoenix.PubSub` is not supervised (embedded
  or standalone-script usage where the consumer skipped the dashboard subtree).
  """

  @pubsub Harness.PubSub

  @doc "Returns the PubSub topic for `run_id`'s transcript stream."
  @spec topic(String.t()) :: String.t()
  def topic(run_id) when is_binary(run_id), do: "harness:run:" <> run_id <> ":transcript"

  @doc "Subscribes the calling process to `run_id`'s transcript chunks. No-op if PubSub is not running."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) when is_binary(run_id) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.subscribe(@pubsub, topic(run_id))
    else
      :ok
    end
  end

  @doc "Stops the calling process from receiving `run_id`'s transcript chunks."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(run_id) when is_binary(run_id) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic(run_id))
    else
      :ok
    end
  end

  @doc """
  Broadcasts a transcript `chunk` for `run_id`.

  Called by the driver loop's `:output` branch (via the `:on_output` callback
  set up by `Harness.Run`). Subscribers receive
  `{:harness_transcript, run_id, data}`. Silent no-op when the PubSub server
  is not running, so a driver embedded in a non-dashboard context never fails
  on a missing bus.
  """
  @spec broadcast(String.t(), iodata()) :: :ok
  def broadcast(run_id, chunk) when is_binary(run_id) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, topic(run_id), {:harness_transcript, run_id, chunk})
    end

    :ok
  end
end
