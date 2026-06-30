defmodule Harness.DepFreshness.Row do
  @moduledoc """
  One dependency freshness fact from a language provider scan.

  Mechanical fields only — harness never judges whether to upgrade.
  """

  @enforce_keys [:name, :current_version, :latest_version, :constraint_allowed]
  defstruct [:name, :current_version, :latest_version, :constraint_allowed]

  @type t :: %__MODULE__{
          name: String.t(),
          current_version: String.t(),
          latest_version: String.t(),
          constraint_allowed: boolean()
        }

  @doc "Returns whether the provider reported a newer version than the locked one."
  @spec outdated?(t()) :: boolean()
  def outdated?(%__MODULE__{current_version: current, latest_version: latest}) do
    current != latest
  end

  @doc "Builds a row map suitable for JSON persistence."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = row) do
    %{
      "name" => row.name,
      "current_version" => row.current_version,
      "latest_version" => row.latest_version,
      "constraint_allowed" => row.constraint_allowed
    }
  end

  @doc "Hydrates a row from a persisted map."
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      name: fetch_string(map, "name"),
      current_version: fetch_string(map, "current_version"),
      latest_version: fetch_string(map, "latest_version"),
      constraint_allowed: fetch_bool(map, "constraint_allowed")
    }
  end

  @spec fetch_string(map(), String.t()) :: String.t()
  defp fetch_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) -> value
      nil -> ""
      value when is_atom(value) -> Atom.to_string(value)
      _other -> ""
    end
  end

  @spec fetch_bool(map(), String.t()) :: boolean()
  defp fetch_bool(map, key) do
    case fetch_value(map, key) do
      true -> true
      false -> false
      _other -> false
    end
  end

  @spec fetch_value(map(), String.t()) :: term()
  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key(key))
    end
  end

  @spec atom_key(String.t()) :: atom()
  defp atom_key("name"), do: :name
  defp atom_key("current_version"), do: :current_version
  defp atom_key("latest_version"), do: :latest_version
  defp atom_key("constraint_allowed"), do: :constraint_allowed
end
