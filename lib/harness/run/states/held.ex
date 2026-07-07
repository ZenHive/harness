defmodule Harness.Run.States.Held do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4]
  import Harness.Run.Actions.Control, only: [fail: 2, hold_enter_actions: 1]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2, status_snapshot: 2]

  alias Harness.Dashboard.RunFeed

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  # ── State: held — operator-parked, worktree retained ─────────────────────

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:held, data)
    RunFeed.broadcast_update(status_snapshot(:held, data))
    {:keep_state, data, hold_enter_actions(data)}
  end

  def handle(:state_timeout, :held_expired, data) do
    fail(data, :hold_expired)
  end

  def handle(event_type, event_content, data) do
    handle_common(event_type, event_content, :held, data)
  end
end
