defmodule Harness.ToolingBaseline.Item do
  @moduledoc """
  One enforceable tooling-baseline check from a language provider scan.

  Mechanical fields only — harness never judges whether drift should be fixed.
  """

  @enforce_keys [:id, :label, :category, :status]
  defstruct [:id, :label, :category, :status, :override_reason]

  @atom_keys %{
    "id" => :id,
    "label" => :label,
    "category" => :category,
    "status" => :status,
    "override_reason" => :override_reason
  }

  @type category :: :dep | :alias | :config_file | :provider
  @type status :: :present | :missing | :overridden | :skipped

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          category: category(),
          status: status(),
          override_reason: String.t() | nil
        }

  @doc "Returns whether the item counts as baseline drift."
  @spec drift?(t()) :: boolean()
  def drift?(%__MODULE__{status: :missing}), do: true
  def drift?(%__MODULE__{}), do: false

  @doc "Builds a visible fact for a language provider that could not run."
  @spec skipped(atom(), term()) :: t()
  def skipped(language, reason) when is_atom(language) do
    %__MODULE__{
      id: "provider:#{language}",
      label: Atom.to_string(language),
      category: :provider,
      status: :skipped,
      override_reason: inspect(reason)
    }
  end

  @doc "Builds a persistence map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = item) do
    %{
      "id" => item.id,
      "label" => item.label,
      "category" => Atom.to_string(item.category),
      "status" => Atom.to_string(item.status),
      "override_reason" => item.override_reason
    }
  end

  @doc "Hydrates an item from a persisted map."
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      id: fetch_string(map, "id"),
      label: fetch_string(map, "label"),
      category: fetch_category(map, "category"),
      status: fetch_status(map, "status"),
      override_reason: fetch_optional_string(map, "override_reason")
    }
  end

  @spec fetch_string(map(), String.t()) :: String.t()
  defp fetch_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> ""
    end
  end

  @spec fetch_optional_string(map(), String.t()) :: String.t() | nil
  defp fetch_optional_string(map, key) do
    case fetch_value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  @spec fetch_category(map(), String.t()) :: category()
  defp fetch_category(map, key) do
    case fetch_string(map, key) do
      "alias" -> :alias
      "config_file" -> :config_file
      "provider" -> :provider
      _other -> :dep
    end
  end

  @spec fetch_status(map(), String.t()) :: status()
  defp fetch_status(map, key) do
    case fetch_string(map, key) do
      "present" -> :present
      "overridden" -> :overridden
      "skipped" -> :skipped
      _other -> :missing
    end
  end

  @spec fetch_value(map(), String.t()) :: term()
  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@atom_keys, key))
    end
  end
end
