defmodule Harness.Run.States.Committing do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4]
  import Harness.Run.Actions.Control, only: [fail: 2]
  import Harness.Run.Actions.Reviewing, only: [route_to_review: 1]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2, start_task: 1, status_snapshot: 2]
  import Harness.Run.Actions.Worktree, only: [commit_message: 1, commit_worktree: 3]

  alias Harness.Dashboard.RunFeed

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  # ── State: committing — capture the implementer's work on the run branch ──

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:committing, data)
    RunFeed.broadcast_update(status_snapshot(:committing, data))
    worktree = data.worktree
    message = commit_message(data)
    task = start_task(fn -> commit_worktree(data, worktree, message) end)
    {:keep_state, %{data | task: task}}
  end

  def handle(:info, {ref, {:ok, :committed, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    route_to_review(%{data | task: nil, agent_diff_size: diff_size})
  end

  # An empty diff is never disposed of here — what it *means* (already
  # implemented vs nothing happened) is the reviewer's judgment, not a
  # disposition branch. The reviewer gets the empty-diff context in its prompt
  # and decides: approve (already implemented / fixed it itself) or reject
  # (nothing to salvage).
  def handle(:info, {ref, {:ok, :no_changes, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    route_to_review(%{data | task: nil, agent_diff_size: diff_size, implementer_empty_diff?: true})
  end

  def handle(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:commit_failed, reason})
  end

  def handle(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:commit_failed, reason})
  end

  def handle(event_type, event_content, data) do
    handle_common(event_type, event_content, :committing, data)
  end
end
