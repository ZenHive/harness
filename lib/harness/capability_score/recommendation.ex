defmodule Harness.CapabilityScore.Recommendation do
  @moduledoc false

  @enforce_keys [:agent, :facets, :strategy, :rationale, :ranked]
  defstruct [
    :agent,
    :facets,
    :strategy,
    :rationale,
    :scout_reasoning,
    :matched_facet,
    ranked: []
  ]

  @type t :: %__MODULE__{
          agent: atom(),
          facets: %{optional(String.t()) => term()},
          strategy: :exploit | :explore | :fallback_no_data,
          rationale: atom() | String.t(),
          scout_reasoning: String.t() | nil,
          matched_facet: %{optional(String.t()) => term()} | nil,
          ranked: [map()]
        }

  @doc false
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields), do: struct!(__MODULE__, fields)
end
