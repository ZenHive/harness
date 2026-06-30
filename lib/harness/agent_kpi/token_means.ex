defmodule Harness.AgentKPI.TokenMeans do
  @moduledoc """
  Mean token counts per run for one agent, by component.

  Fields mirror `Harness.TokenUsage` field names: `input`, `output`, and
  `total`. Each value is a `float()` — the mean across an agent's full run
  set, with absent (nil) components counted as `0`.
  """

  # Serialized directly into the capability-scout assessment JSON artifact
  # (CapabilityScore.save_assessment), where it was a plain map before becoming a
  # struct — derive all three numeric fields to reproduce that JSON exactly.
  @derive Jason.Encoder
  @enforce_keys [:input, :output, :total]

  @typedoc "Mean token counts per run for one agent, by component."
  @type t :: %__MODULE__{
          input: float(),
          output: float(),
          total: float()
        }

  defstruct [:input, :output, :total]
end
