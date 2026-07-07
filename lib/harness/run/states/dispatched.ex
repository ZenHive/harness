defmodule Harness.Run.States.Dispatched do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4]
  import Harness.Run.Actions.Control, only: [fail: 2]
  import Harness.Run.Actions.Reviewing, only: [maybe_validate_implementer_isolation: 1, route_after_dispatch: 1]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2, start_task: 1, status_snapshot: 2]
  import Harness.Run.Actions.Worktree, only: [worktree_opts: 1]

  alias Harness.Dashboard.RunFeed
  alias Harness.Worktree
  alias Harness.Worktree.Reaper

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  # ── State: dispatched — carve the isolated worktree ──────────────────────

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:dispatched, data)
    RunFeed.broadcast_update(status_snapshot(:dispatched, data))
    task = start_task(fn -> Worktree.create(data.project, worktree_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  # The worktree exists — warm it, then hand it to the agent. Warming is a
  # mechanical byte-copy of the parent checkout's gitignored build artifacts
  # (deps/_build/PLT) into the fresh tree, so the implementer doesn't cold-fetch
  # deps and the reviewer doesn't cold-compile + cold-build the dialyzer PLT. It
  # is a pure optimization, never a gate — `warm/2` always returns `:ok`; a copy
  # that fails just means the agent cold-builds that path. (Mechanics, not
  # judgment: copying bytes — the mantra-clean half of the warm step the
  # agent-gate rebuild deleted along with Harness.Verification.)
  def handle(:info, {ref, {:ok, %Worktree{} = worktree}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil, worktree: worktree}

    with :ok <- Worktree.activate(worktree),
         :ok <- Worktree.warm(worktree, warm_paths: data.project.warm_paths),
         :ok <- maybe_validate_implementer_isolation(data) do
      # Crash reaper (Task 185): once the worktree is live, a hard crash of this
      # gen_statem before settle would leak it; the reaper monitors us and reaps
      # on an abnormal :DOWN. settle/2 untracks once the worktree is finalized.
      Reaper.track(self(), data.run_id, worktree.path, worktree.repo)
      route_after_dispatch(data)
    else
      {:error, {:worktree_isolation_unsupported, _adapter, _message} = reason} ->
        fail(data, {:agent_spawn_failed, reason})

      {:error, reason} ->
        fail(data, {:worktree_failed, reason})
    end
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
