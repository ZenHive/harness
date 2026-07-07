defmodule Harness.Routing.Availability do
  @moduledoc false

  @enforce_keys [:model, :model_required, :label, :available, :blocked]
  defstruct [
    :model,
    :model_required,
    :label,
    :available,
    :blocked,
    reason: nil,
    source: nil,
    until: nil
  ]

  @type t :: %__MODULE__{
          model: String.t() | nil,
          model_required: boolean(),
          label: String.t() | nil,
          available: boolean(),
          blocked: boolean(),
          reason: String.t() | nil,
          source: Harness.ModelAvailability.block_source() | nil,
          until: DateTime.t() | nil
        }

  @doc false
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields), do: struct!(__MODULE__, fields)
end
