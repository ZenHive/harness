defmodule Harness.Verification.Verdict do
  @moduledoc """
  The aggregate outcome of a verification run: every check's result plus the
  single objective pass/fail the harness grades the run on.

  Any agent-attributed red check makes the whole verdict red. When every red
  check also fails on the dispatch base, the verdict is `:base_red` instead:
  not green, but not blamed on the agent.
  """

  alias Harness.Verification.Result

  @typedoc """
  The verdict.

    * `status` — `:pass` only when every result passed; `:fail` if any
      agent-attributed check failed; `:base_red` when all failures were
      inherited from the dispatch base.
    * `results` — every check's `Harness.Verification.Result`, in the order the
      checks ran.
  """
  @type t :: %__MODULE__{
          status: :pass | :fail | :base_red,
          results: [Result.t()]
        }

  @enforce_keys [:status, :results]
  defstruct [:status, :results]

  @doc """
  Whether every check in the verdict passed.

  `:base_red` is deliberately not passed: inherited red must never silently
  green a run.
  """
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{status: status}), do: status == :pass
end
