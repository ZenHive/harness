defmodule Harness.Dashboard.RunFeed do
  @moduledoc """
  Fleet-wide run-lifecycle PubSub for the dashboard's event-driven run tables.

  Sibling to `Harness.Dashboard.Transcript` (which carries per-run transcript
  chunks on `"harness:run:<id>:transcript"`). Where the transcript feed is
  per-run, this feed is *fleet-wide*: one topic (`"harness:runs"`) carries the
  lifecycle of every run so a single dashboard subscription can drive the
  "Active runs" and "Run history" tables without polling.

  The `Harness.Run` gen_statem emits two message shapes:

    * `{:harness_run_update, %Harness.Run.Status{}}` — on each **non-terminal**
      state-enter (dispatched/running/committing/verifying/reviewing). Covers
      "a new run appeared" and every live state / review-iteration change. The
      dashboard `stream_insert`s the row (dom-id-keyed, so repeated updates
      patch in place).
    * `{:harness_run_settled, %Harness.Run.Status{}}` — once, from `settle/2`
      on the terminal (`:done` / `:failed`) enter. The dashboard removes the
      row from the active stream and prepends it to history.

  Terminal states broadcast **only** the settled shape — never a redundant
  update — so a row never round-trips through "active, then gone".

  ## PubSub guard

  Broadcast and subscribe are guarded by `Process.whereis(Harness.PubSub)` so a
  run executed in a non-dashboard runtime (consumer skipped the dashboard
  subtree) never fails on a missing bus — mirrors `Harness.Dashboard.Transcript`.
  """

  alias Harness.Run.Status

  @pubsub Harness.PubSub
  @topic "harness:runs"

  @doc "The fleet-wide run-lifecycle PubSub topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to the fleet run-lifecycle feed. No-op if PubSub is not running."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.subscribe(@pubsub, @topic)
    else
      :ok
    end
  end

  @doc "Stops the calling process from receiving fleet run-lifecycle messages."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.unsubscribe(@pubsub, @topic)
    else
      :ok
    end
  end

  @doc """
  Broadcasts a non-terminal `status` update.

  Subscribers receive `{:harness_run_update, status}`. Called from each
  non-terminal `:enter` clause of the `Harness.Run` gen_statem. Silent no-op
  when the PubSub server is not running.
  """
  @spec broadcast_update(Status.t()) :: :ok
  def broadcast_update(%Status{} = status) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:harness_run_update, status})
    end

    :ok
  end

  @doc """
  Broadcasts the terminal `status` of a settled run.

  Subscribers receive `{:harness_run_settled, status}`. Called once from
  `Harness.Run`'s `settle/2`, after the result is persisted and delivered.
  Silent no-op when the PubSub server is not running.
  """
  @spec broadcast_settled(Status.t()) :: :ok
  def broadcast_settled(%Status{} = status) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:harness_run_settled, status})
    end

    :ok
  end
end
