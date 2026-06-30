defmodule Harness.ToolingBaseline.Snapshot do
  @moduledoc """
  Latest tooling-baseline conformance facts for one registered project.
  """

  alias Harness.ToolingBaseline.Advisory
  alias Harness.ToolingBaseline.Item

  @enforce_keys [:checked_at, :drift_count, :items, :advisory]
  defstruct [:checked_at, :drift_count, items: [], advisory: []]

  @type t :: %__MODULE__{
          checked_at: DateTime.t(),
          drift_count: non_neg_integer(),
          items: [Item.t()],
          advisory: [Advisory.t()]
        }

  @doc "Counts items whose baseline requirement is absent and not overridden."
  @spec drift_count([Item.t()]) :: non_neg_integer()
  def drift_count(items) when is_list(items) do
    Enum.count(items, &Item.drift?/1)
  end

  @doc "Builds a snapshot from provider items, stamping `checked_at` mechanically."
  @spec build([Item.t()], [Advisory.t()], DateTime.t()) :: t()
  def build(items, advisory, checked_at \\ DateTime.utc_now(:millisecond)) when is_list(items) and is_list(advisory) do
    %__MODULE__{
      checked_at: checked_at,
      drift_count: drift_count(items),
      items: items,
      advisory: advisory
    }
  end

  @doc "Serializes the snapshot for JSON persistence."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      "checked_at" => DateTime.to_iso8601(snapshot.checked_at),
      "drift_count" => snapshot.drift_count,
      "items" => Enum.map(snapshot.items, &Item.to_map/1),
      "advisory" => Enum.map(snapshot.advisory, &Advisory.to_map/1)
    }
  end

  @doc "Hydrates a snapshot from persisted JSON."
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    items = map |> Map.get("items", []) |> Enum.map(&Item.from_map/1)
    advisory = map |> Map.get("advisory", []) |> Enum.map(&Advisory.from_map/1)

    %__MODULE__{
      checked_at: parse_checked_at(map["checked_at"]),
      drift_count: Map.get(map, "drift_count", drift_count(items)),
      items: items,
      advisory: advisory
    }
  end

  @spec parse_checked_at(term()) :: DateTime.t()
  defp parse_checked_at(checked_at) when is_binary(checked_at) do
    case DateTime.from_iso8601(checked_at) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> DateTime.utc_now(:millisecond)
    end
  end

  defp parse_checked_at(%DateTime{} = checked_at), do: checked_at
  defp parse_checked_at(_other), do: DateTime.utc_now(:millisecond)
end
