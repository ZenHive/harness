defmodule Harness.Dispatch.AwaitRunsSummary do
  @moduledoc false

  @enforce_keys [:run_id, :state]
  defstruct [:run_id, :state, :reason, :review_verdict]

  @type t :: %__MODULE__{
          run_id: String.t(),
          state: atom(),
          reason: term(),
          review_verdict: atom() | nil
        }

  @doc false
  @spec new(String.t(), atom(), term(), atom() | nil) :: t()
  def new(run_id, state, reason, review_verdict \\ nil) do
    %__MODULE__{run_id: run_id, state: state, reason: reason, review_verdict: review_verdict}
  end
end
