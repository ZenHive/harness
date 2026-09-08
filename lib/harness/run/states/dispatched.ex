defmodule Harness.Run.States.Dispatched do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4]
  import Harness.Run.Actions.Control, only: [fail: 2]
  import Harness.Run.Actions.Reviewing, only: [maybe_validate_implementer_isolation: 1, route_after_dispatch: 1]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2, start_task: 1, status_snapshot: 2]
  import Harness.Run.Actions.Worktree, only: [worktree_opts: 1]

  alias Harness.Dashboard.RunFeed

  # ── State: dispatched — carve the isolated worktree ──────────────────────
  alias Harness.ProjectCache
  alias Harness.Worktree
  alias Harness.Worktree.Reaper

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:dispatched, data)
    RunFeed.broadcast_update(status_snapshot(:dispatched, data))
    task = start_task(fn -> Worktree.create(data.project, worktree_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  # Keep preparation off the gen_statem so cancellation and lifetime timers
  # remain responsive while concurrent runs wait for the same cache builder.
  def handle(:info, {ref, {:ok, %Worktree{} = worktree}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil, worktree: worktree}

    with :ok <- Worktree.activate(worktree),
         :ok <- maybe_validate_implementer_isolation(data) do
      Reaper.track(self(), data.run_id, worktree.path, worktree.repo)

      task =
        start_task(fn ->
          :ok = ProjectCache.warm(worktree, data.project.cache_preparation, warm_paths: data.project.warm_paths)
          {:warmed, worktree}
        end)

      {:keep_state, %{data | task: task}}
    else
      {:error, {:worktree_isolation_unsupported, _, _} = reason} -> fail(data, {:agent_spawn_failed, reason})
      {:error, reason} -> fail(data, {:worktree_failed, reason})
    end
  end

  def handle(:info, {ref, {:warmed, %Worktree{}}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil}

    route_after_dispatch(data)
  end

  def handle(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:worktree_failed, reason})
  end

  def handle(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:worktree_failed, reason})
  end

  def handle(event_type, event_content, data) do
    handle_common(event_type, event_content, :dispatched, data)
  end
end
