defmodule Harness.Verification.Verdict do
  @moduledoc """
  The aggregate outcome of a verification run: every check's result plus the
  single objective pass/fail the harness grades the run on.

  Any red check makes the whole verdict red. What a red check *means* — and
  what to do about it — is the cross-family reviewer's judgment, never a
  classification harness makes itself (docs/reviewer-pair-architecture.md).
  """

  alias Harness.Verification.Result

  @typedoc """
  The verdict.

    * `status` — `:pass` only when every result passed; `:fail` if any check
      failed.
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
  """
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{status: status}), do: status == :pass
end
