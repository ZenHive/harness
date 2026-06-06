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
      state-enter (dispatched/running/committing/recovering/reviewing). Covers
      "a new run appeared" and every live state change. The
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

  alias Harness.Dashboard.RoadmapSummary
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Run.Status

  @pubsub Harness.PubSub
  @topic "harness:runs"

  @doc "The fleet-wide run-lifecycle PubSub topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Returns the reconciled landed SHA for a run status.

  Roadmap `shipped_in` remains the fast witness when present. Otherwise the feed
  checks whether the run's retained branch, or an equivalent rebased run commit,
  is reachable from the project's `origin/<target_branch>`.
  """
  @spec landed_sha(Status.t(), RoadmapSummary.summaries(), [Project.t()]) :: String.t() | nil
  def landed_sha(%Status{} = status, summaries, projects) when is_map(summaries) and is_list(projects) do
    roadmap_landed_sha(status, summaries) || branch_landed_sha(status, projects)
  end

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

  @spec roadmap_landed_sha(Status.t(), RoadmapSummary.summaries()) :: String.t() | nil
  defp roadmap_landed_sha(%Status{project_name: project, task_id: task_id}, summaries) do
    RoadmapSummary.landed_sha(summaries, project, task_id)
  end

  @spec branch_landed_sha(Status.t(), [Project.t()]) :: String.t() | nil
  defp branch_landed_sha(%Status{project_name: project_name} = status, projects) do
    case project_by_name(projects, project_name) do
      %Project{} = project -> ResultStore.landed_sha(status, project)
      nil -> nil
    end
  end

  @spec project_by_name([Project.t()], String.t() | nil) :: Project.t() | nil
  defp project_by_name(projects, name) when is_binary(name) do
    Enum.find(projects, &(&1.name == name))
  end

  defp project_by_name(_projects, _name), do: nil
end
