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
  alias Harness.AgentRegistry
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Review

  @typedoc "The lifecycle state a run is currently in."
  @type state ::
          :dispatched
          | :running
          | :committing
          | :recovering
          | :reviewing
          | :held
          | :done
          | :failed

  @typedoc """
  A run snapshot.

    * `run_id` — the run's unique id.
    * `task_id` — the rmap task id the run serves.
    * `state` — the current lifecycle state (see `t:state/0`).
    * `worktree_path` — the isolated worktree's path, or `nil` before it exists.
    * `agent_os_pid` — the agent's OS pid, captured once at spawn. `nil` before
      the agent has spawned and after a cancellation or failure clears the run
      handle; otherwise it stays the spawn-time pid through `reviewing` and the
      terminal states, even though the agent process has already exited.
    * `agent` — the executing adapter's identity atom (`:claude` / `:cursor` /
      …), resolved at run start; `nil` for an unregistered adapter / test double.
      Distinct from `agent_kind`, which is the *outcome* kind, not the identity.
    * `model` — the LLM model for this run: the agent-reported id when present
      (claude / cursor self-report in their transcript), else the task's pinned
      requested model, else `nil`.
    * `agent_kind` — how the agent run ended (`t:Harness.AgentAdapter.Outcome.kind/0`),
      or `nil` before the agent has finished.
    * `reviewer_adapter` — the reviewing agent's identity atom (`:claude` / …),
      resolved when the run routes into `:reviewing`; `nil` before review and for
      runs whose reviewer module is unregistered. Distinct from `agent` (the
      *implementer*) so the dashboard can name *who is reviewing*, not just that
      the run reached `:reviewing`.
    * `recovery_adapter` — the recovery agent's identity atom while the run is in
      `:recovering`; `nil` otherwise. Not persisted on the settled record, so it
      is populated only for live runs.
    * `review_verdict` — the reviewer's decision (`:approve` / `:reject`), or
      `nil` before the reviewer has written its verdict artifact.
    * `reason` — why the run settled or is failing, once known (see
      `t:Harness.Run.Result.reason/0`); `nil` while the run is still in flight.
    * `held?` — `true` while the run is operator-parked in `:held`.
    * `hold_reason` — `:graceful` or `:interrupt` when `held?` is true; `nil`
      otherwise.
    * `landed_sha` — the durable landing witness written by the lander when the
      run's commit is fast-forward-pushed; nil for unlanded and pre-column rows.
  """
  @type t :: %__MODULE__{
          run_id: String.t(),
          task_id: String.t(),
          project_name: String.t() | nil,
          agent: atom() | nil,
          model: String.t() | nil,
          state: state(),
          worktree_path: String.t() | nil,
          agent_os_pid: non_neg_integer() | nil,
          agent_kind: Outcome.kind() | nil,
          reviewer_adapter: atom() | nil,
          recovery_adapter: atom() | nil,
          review_verdict: Review.verdict() | nil,
          reason: Result.reason() | nil,
          held?: boolean(),
          hold_reason: :graceful | :interrupt | nil,
          landed_sha: String.t() | nil
        }

  @enforce_keys [:run_id, :task_id, :state]
  defstruct [
    :run_id,
    :task_id,
    :project_name,
    :agent,
    :model,
    :state,
    :worktree_path,
    :agent_os_pid,
    :agent_kind,
    :reviewer_adapter,
    :recovery_adapter,
    :review_verdict,
    :reason,
    :landed_sha,
    :hold_reason,
    held?: false
  ]

  @doc """
  Reconstructs a `Status` snapshot from a settled `Harness.Run.LogRecord`.

  Where `status/1` reads a *live* run's gen_statem, this rebuilds the same
  shape from the persisted record so the dashboard can render runs that no
  longer have a process (e.g. after a BEAM restart). The record's settled
  `state` is always `:done` or `:failed`, so the resulting `Status` classifies
  as a terminal (and thus non-killable) run. `worktree_path` and `agent_os_pid`
  are not retained on the record, so both are `nil`.
  """
  @spec from_log_record(LogRecord.t()) :: t()
  def from_log_record(%LogRecord{} = record) do
    %__MODULE__{
      run_id: record.run_id,
      task_id: record.task_id,
      # Map.get (not record.project_name) so records persisted before this field
      # existed decode without a KeyError — they simply filter as "no project".
      project_name: Map.get(record, :project_name),
      agent: Map.get(record, :agent),
      model: Map.get(record, :model),
      state: state_from_log_record(record),
      worktree_path: nil,
      agent_os_pid: nil,
      agent_kind: record.agent_outcome_kind,
      # The record stores the reviewer as a *module*; convert to the identity
      # atom for display parity with `agent`. recovery_adapter is not persisted,
      # so it stays nil on a rehydrated (settled) status.
      reviewer_adapter: agent_atom(Map.get(record, :reviewer_adapter)),
      recovery_adapter: nil,
      review_verdict: Map.get(record, :verdict),
      reason: record.reason,
      landed_sha: Map.get(record, :landed_sha)
    }
  end

  @spec state_from_log_record(LogRecord.t()) :: state()
  defp state_from_log_record(%LogRecord{state: state}) when state in [:done, :failed], do: state
  defp state_from_log_record(%LogRecord{}), do: :failed

  @spec agent_atom(module() | nil) :: atom() | nil
  defp agent_atom(nil), do: nil

  defp agent_atom(module) when is_atom(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> agent
      {:error, _} -> nil
    end
  end
end
