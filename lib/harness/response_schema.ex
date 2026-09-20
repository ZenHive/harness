defmodule Harness.ResponseSchema do
  @moduledoc "Shared strict JSON schema constructors for provider responses."

  @doc "Builds a strict object requiring every supplied property."
  @spec object(map()) :: map()
  def object(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }

  @doc "Builds an array of the supplied item schema."
  @spec array(map()) :: map()
  def array(items), do: %{"type" => "array", "items" => items}
end
