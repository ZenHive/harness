defmodule Harness.Run.Status do
  @moduledoc """
  A live snapshot of a `Harness.Run` lifecycle, returned by
  `Harness.Run.status/1`.

  Where `Harness.Run.Result` is the *final* outcome delivered once, a `Status`
  can be queried at any point while the run is in flight — it reports the
  current state and whatever the run has produced so far. Fields that the run
  has not reached yet are `nil`.
  """

  alias Harness.AgentAdapter.Outcome

  @typedoc "The lifecycle state a run is currently in."
  @type state :: :dispatched | :running | :committing | :verifying | :done | :failed

  @typedoc """
  A run snapshot.

    * `run_id` — the run's unique id.
    * `task_id` — the rmap task id the run serves.
    * `state` — the current lifecycle state (see `t:state/0`).
    * `worktree_path` — the isolated worktree's path, or `nil` before it exists.
    * `agent_os_pid` — the agent's OS pid, captured once at spawn. `nil` before
      the agent has spawned and after a cancellation or failure clears the run
      handle; otherwise it stays the spawn-time pid through `verifying` and the
      terminal states, even though the agent process has already exited.
    * `agent_kind` — how the agent run ended (`t:Harness.AgentAdapter.Outcome.kind/0`),
      or `nil` before the agent has finished.
    * `verdict_status` — the verification verdict (`:pass` / `:fail`), or `nil`
      before verification has finished.
  """
  @type t :: %__MODULE__{
          run_id: String.t(),
          task_id: String.t(),
          state: state(),
          worktree_path: String.t() | nil,
          agent_os_pid: non_neg_integer() | nil,
          agent_kind: Outcome.kind() | nil,
          verdict_status: :pass | :fail | nil
        }

  @enforce_keys [:run_id, :task_id, :state]
  defstruct [:run_id, :task_id, :state, :worktree_path, :agent_os_pid, :agent_kind, :verdict_status]
end
