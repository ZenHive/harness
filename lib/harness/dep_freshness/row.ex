defmodule Harness.DepFreshness.Row do
  @moduledoc """
  One dependency freshness fact from a language provider scan.

  Mechanical fields only — harness never judges whether to upgrade.
  """

  @enforce_keys [:name, :current_version, :latest_version, :constraint_allowed]
  defstruct [:name, :current_version, :latest_version, :constraint_allowed, :language, status: :ok, reason: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          current_version: String.t(),
          latest_version: String.t(),
          constraint_allowed: boolean(),
          language: atom() | nil,
          status: :ok | :skipped,
          reason: term()
        }

  @doc "Returns whether the provider reported a newer version than the locked one."
  @spec outdated?(t()) :: boolean()
  def outdated?(%__MODULE__{status: :ok, current_version: current, latest_version: latest}) do
    current != latest
  end

  def outdated?(%__MODULE__{}), do: false

  @doc "Builds a row map suitable for JSON persistence."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = row) do
    %{
      "name" => row.name,
      "current_version" => row.current_version,
      "latest_version" => row.latest_version,
      "constraint_allowed" => row.constraint_allowed,
      "language" => atom_to_string(row.language),
      "status" => Atom.to_string(row.status),
      "reason" => reason_to_string(row.reason)
    }
  end

  @doc "Hydrates a row from a persisted map."
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      name: fetch_string(map, "name"),
      current_version: fetch_string(map, "current_version"),
      latest_version: fetch_string(map, "latest_version"),
      constraint_allowed: fetch_bool(map, "constraint_allowed"),
      language: fetch_optional_atom(map, "language"),
      status: fetch_status(map, "status"),
      reason: fetch_optional_string(map, "reason")
    }
  end

  @doc "Builds a visible fact for a language provider that could not run."
  @spec skipped(atom(), term()) :: t()
  def skipped(language, reason) when is_atom(language) do
    %__MODULE__{
      name: "provider:#{language}",
      current_version: "skipped",
      latest_version: "skipped",
      constraint_allowed: false,
      language: language,
      status: :skipped,
      reason: reason
    }
  end

  @spec atom_to_string(atom() | nil) :: String.t() | nil
  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  @spec reason_to_string(term()) :: String.t() | nil
  defp reason_to_string(nil), do: nil
  defp reason_to_string(reason), do: inspect(reason)

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

  @spec fetch_optional_atom(map(), String.t()) :: atom() | nil
  defp fetch_optional_atom(map, key) do
    case fetch_value(map, key) do
      nil -> nil
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec fetch_status(map(), String.t()) :: :ok | :skipped
  defp fetch_status(map, key) do
    case fetch_string(map, key) do
      "skipped" -> :skipped
      _other -> :ok
    end
  end

  @spec fetch_optional_string(map(), String.t()) :: String.t() | nil
  defp fetch_optional_string(map, key) do
    case fetch_value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> nil
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
  defp atom_key("language"), do: :language
  defp atom_key("status"), do: :status
  defp atom_key("reason"), do: :reason
end
