defmodule Harness.ToolingBaseline.Advisory do
  @moduledoc """
  Operator-machine surface called out as advisory, never enforced.
  """

  @enforce_keys [:id, :label, :description]
  defstruct [:id, :label, :description]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          description: String.t()
        }

  @doc "Builds a persistence map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = advisory) do
    %{
      "id" => advisory.id,
      "label" => advisory.label,
      "description" => advisory.description
    }
  end

  @doc "Hydrates an advisory from a persisted map."
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      id: fetch_string(map, "id"),
      label: fetch_string(map, "label"),
      description: fetch_string(map, "description")
    }
  end

  @spec fetch_string(map(), String.t()) :: String.t()
  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> value
      :error -> map |> Map.get(String.to_atom(key), "") |> to_string()
    end
  end
end
