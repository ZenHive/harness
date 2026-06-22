defmodule Harness.Dashboard.Feed do
  @moduledoc false
  # Shared Phoenix.PubSub subscribe/unsubscribe guard for the dashboard's
  # fleet-wide feeds (`RunFeed`, `OpsFeed`). Each feed owns its own `@pubsub`,
  # `@topic`, and event structs; only the guard — a no-op when the bus is not
  # running — is shared, so a run executed in a non-dashboard runtime (consumer
  # skipped the dashboard subtree) never crashes on a missing PubSub.

  @doc "Subscribes the caller to `topic` on `pubsub`. No-op if PubSub is not running."
  @spec subscribe(atom(), String.t()) :: :ok | {:error, term()}
  def subscribe(pubsub, topic) do
    if Process.whereis(pubsub), do: Phoenix.PubSub.subscribe(pubsub, topic), else: :ok
  end

  @doc "Unsubscribes the caller from `topic` on `pubsub`. No-op if PubSub is not running."
  @spec unsubscribe(atom(), String.t()) :: :ok
  def unsubscribe(pubsub, topic) do
    if Process.whereis(pubsub), do: Phoenix.PubSub.unsubscribe(pubsub, topic), else: :ok
  end
end
