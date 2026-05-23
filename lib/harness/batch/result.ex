defmodule Harness.Batch.Result do
  @moduledoc """
  The aggregate outcome of running a set of roadmap items as one batch.

  The batch itself succeeds when every task reached a terminal run result. A red
  or failed task remains a `Harness.Run.Result` inside `results`; it does not
  abort the rest of the batch.
  """

  alias Harness.Run.Result, as: RunResult

  @typedoc """
  A settled batch.

    * `total` — number of input tasks.
    * `max_concurrency` — cap used while fanning tasks out.
    * `results` — one terminal run result per input task, in input order.
    * `events` — observable routing events emitted by the batch orchestrator.
  """
  @type t :: %__MODULE__{
          total: non_neg_integer(),
          max_concurrency: pos_integer(),
          results: [RunResult.t()],
          events: [term()]
        }

  @enforce_keys [:total, :max_concurrency, :results]
  defstruct [:total, :max_concurrency, :results, events: []]
end
