defmodule Harness.Verification.Verdict do
  @moduledoc """
  The aggregate outcome of a verification run: every check's result plus the
  single objective pass/fail the harness grades the run on.

  Any red check makes the whole verdict red — harness never marks a job green
  unless every check in the stack passed.
  """

  alias Harness.Verification.Result

  @typedoc """
  The verdict.

    * `status` — `:pass` only when every result passed; `:fail` if any failed.
    * `results` — every check's `Harness.Verification.Result`, in the order the
      checks ran.
  """
  @type t :: %__MODULE__{
          status: :pass | :fail,
          results: [Result.t()]
        }

  @enforce_keys [:status, :results]
  defstruct [:status, :results]

  @doc """
  Whether every check in the verdict passed.

  The run-lifecycle maps this onto the `:success` / `:failure` outcome of
  `Harness.Worktree.finish/3`.
  """
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{status: status}), do: status == :pass
end
