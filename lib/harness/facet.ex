defmodule Harness.Facet do
  @moduledoc false
  # Shared normalization for routing "facet" maps — the open-vocabulary task-kind
  # key the reviewer writes and capability routing groups on. Dropping nil values
  # and stringifying keys gives facets a single canonical shape so they compare,
  # sort, and serialize identically across the capability-scoring and dashboard
  # surfaces (which previously each carried their own copy).

  @doc """
  Normalizes a facet into a string-keyed map with nil values removed.

  A non-map (e.g. `nil`) normalizes to the empty map.

  ## Examples

      iex> Harness.Facet.normalize(%{lang: "elixir", area: nil})
      %{"lang" => "elixir"}

      iex> Harness.Facet.normalize(nil)
      %{}
  """
  @spec normalize(term()) :: %{String.t() => term()}
  def normalize(facet) when is_map(facet) do
    facet
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  def normalize(_other), do: %{}
end
