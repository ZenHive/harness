defmodule Harness.AgentAdapter.RuleDelivery do
  @moduledoc false

  @type t :: %__MODULE__{
          argv_flags: [String.t()],
          prompt: String.t() | nil
        }

  defstruct argv_flags: [], prompt: nil
end
