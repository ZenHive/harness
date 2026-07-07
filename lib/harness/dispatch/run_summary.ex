defmodule Harness.Dispatch.RunSummary do
  @moduledoc false

  @enforce_keys [:run_id, :state, :passed]
  defstruct [
    :run_id,
    :task_id,
    :state,
    :reason,
    :passed,
    :agent_diff_size,
    :reviewer_diff_size,
    :worktree_path,
    review: nil
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          task_id: String.t() | nil,
          state: atom(),
          reason: term(),
          passed: boolean(),
          agent_diff_size: non_neg_integer() | nil,
          reviewer_diff_size: non_neg_integer() | nil,
          worktree_path: String.t() | nil,
          review: map() | nil
        }
end
