defmodule Harness.ModelAvailability.CatalogEntry do
  @moduledoc false

  @enforce_keys [:id, :label]
  defstruct [:id, :label, annotations: []]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          annotations: [String.t()]
        }

  @doc false
  @spec new(String.t(), String.t(), [String.t()]) :: t()
  def new(id, label, annotations \\ []) do
    %__MODULE__{id: id, label: label, annotations: annotations}
  end

  @doc false
  @spec coerce(map() | t()) :: t()
  def coerce(%__MODULE__{} = entry), do: entry

  def coerce(%{id: id, label: label} = map) do
    %__MODULE__{
      id: id,
      label: label,
      annotations: Map.get(map, :annotations, Map.get(map, "annotations", []))
    }
  end
end
