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

  @typedoc "Run-id → branch-reachability landed SHA, precomputed off the render path."
  @type landed_cache :: %{optional(String.t()) => String.t()}

  @doc """
  Returns the reconciled landed SHA for a run status — **pure, no git/network**.

  Roadmap `shipped_in` remains the fast witness when present. Otherwise the feed
  consults `landed_cache`, a map of run-id → branch-reachability SHA built off the
  render path by `branch_landed_cache/3` (refreshed on the dashboard's cold-path
  roadmap tick). The old per-row `git fetch` is gone (task 244) — render does map
  lookups only.
  """
  @spec landed_sha(Status.t(), RoadmapSummary.summaries(), landed_cache()) :: String.t() | nil
  def landed_sha(%Status{run_id: run_id} = status, summaries, landed_cache)
      when is_map(summaries) and is_map(landed_cache) do
    roadmap_landed_sha(status, summaries) || Map.get(landed_cache, run_id)
  end

  @doc """
  Cold-path builder for the `landed_cache` consumed by `landed_sha/3`.

  For each status whose task lacks a roadmap `shipped_in` witness, computes the
  branch-reachability landed SHA via `Harness.ResultStore.landed_sha/2` (LOCAL
  refs only — no network fetch) and collects `run_id => sha` for the landed ones.
  Roadmap-covered rows are skipped (the witness already answers them in render),
  so steady-state work is bounded to the genuinely-unwitnessed rows. Call this
  off the render path (e.g. on the dashboard roadmap tick), never during render.
  """
  @spec branch_landed_cache([Status.t()], RoadmapSummary.summaries(), [Project.t()]) :: landed_cache()
  def branch_landed_cache(statuses, summaries, projects)
      when is_list(statuses) and is_map(summaries) and is_list(projects) do
    by_name = Map.new(projects, &{&1.name, &1})

    statuses
    |> Enum.reject(&roadmap_landed_sha(&1, summaries))
    |> Enum.reduce(%{}, fn %Status{run_id: run_id} = status, acc ->
      with %Project{} = project <- Map.get(by_name, status.project_name),
           sha when is_binary(sha) <- ResultStore.landed_sha(status, project) do
        Map.put(acc, run_id, sha)
      else
        _ -> acc
      end
    end)
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
end
