defmodule Harness.Chat.Stream do
  @moduledoc """
  PubSub fan-out for chat session streaming (Task 76).

  The Session GenServer broadcasts normalized stream events on
  `harness:chat:<session_id>:stream`. Subscribers (Task 78 LiveView) receive
  `{:harness_chat_stream, session_id, event}`.
  """

  @pubsub Harness.PubSub

  @doc "Returns the PubSub topic for `session_id`'s chat stream."
  @spec topic(String.t()) :: String.t()
  def topic(session_id) when is_binary(session_id), do: "harness:chat:" <> session_id <> ":stream"

  @doc "Subscribes the calling process to `session_id`'s stream. No-op if PubSub is not running."
  @spec subscribe(String.t()) :: :ok
  def subscribe(session_id) when is_binary(session_id) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
    end

    :ok
  end

  @doc "Stops the calling process from receiving `session_id`'s stream events."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) when is_binary(session_id) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic(session_id))
    end

    :ok
  end

  @doc """
  Broadcasts a structured `event` map for `session_id`.

  Silent no-op when PubSub is not running.
  """
  @spec broadcast(String.t(), map()) :: :ok
  def broadcast(session_id, event) when is_binary(session_id) and is_map(event) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, topic(session_id), {:harness_chat_stream, session_id, event})
    end

    :ok
  end
end
