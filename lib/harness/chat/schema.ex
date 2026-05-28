defmodule Harness.Chat.Schema do
  @moduledoc """
  Minimal JSON Schema validation for MCP tool `inputSchema` maps.

  Covers the subset produced by `Descripex.MCP` — enough to reject malformed
  tool arguments before `apply/3` dispatch.
  """

  @type error :: %{required(:path) => String.t(), required(:message) => String.t()}

  @doc "Validates `data` against `schema`. Returns `:ok` or `{:error, [error]}`."
  @spec validate(map(), map()) :: :ok | {:error, [error()]}
  def validate(data, schema) when is_map(data) and is_map(schema) do
    case validate_value(data, schema, "#") do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @spec validate_value(term(), map(), String.t()) :: [error()]
  defp validate_value(data, schema, path) do
    type = Map.get(schema, "type")

    cond do
      type == "object" ->
        validate_object(data, schema, path)

      type == "array" ->
        validate_array(data, schema, path)

      type == "string" ->
        validate_string(data, schema, path)

      type == "integer" ->
        validate_integer(data, schema, path)

      type == "number" ->
        validate_number(data, schema, path)

      type == "boolean" ->
        validate_boolean(data, schema, path)

      type == nil ->
        []

      true ->
        [error(path, "unsupported schema type #{inspect(type)}")]
    end
  end

  @spec validate_object(term(), map(), String.t()) :: [error()]
  defp validate_object(data, schema, path) when is_map(data) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    additional = Map.get(schema, "additionalProperties", true)

    validate_required_fields(data, required, path) ++
      validate_known_properties(data, properties, additional, path)
  end

  defp validate_object(_data, _schema, path), do: [error(path, "expected object")]

  @spec validate_required_fields(map(), [String.t()], String.t()) :: [error()]
  defp validate_required_fields(data, required, path) do
    Enum.flat_map(required, &required_field_error(data, &1, path))
  end

  @spec required_field_error(map(), String.t(), String.t()) :: [error()]
  defp required_field_error(data, key, path) do
    if Map.has_key?(data, key), do: [], else: [error("#{path}/#{key}", "is required")]
  end

  @spec validate_known_properties(map(), map(), boolean() | map(), String.t()) :: [error()]
  defp validate_known_properties(data, properties, additional, path) do
    Enum.flat_map(data, fn {key, value} ->
      validate_property(key, value, properties, additional, path)
    end)
  end

  @spec validate_property(String.t(), term(), map(), boolean() | map(), String.t()) :: [error()]
  defp validate_property(key, value, properties, additional, path) do
    case Map.fetch(properties, key) do
      {:ok, prop_schema} ->
        validate_value(value, prop_schema, "#{path}/#{key}")

      :error ->
        validate_additional_property(additional, key, path)
    end
  end

  @spec validate_additional_property(boolean() | map(), String.t(), String.t()) :: [error()]
  defp validate_additional_property(false, key, path), do: [error("#{path}/#{key}", "additional property not allowed")]

  defp validate_additional_property(_additional, _key, _path), do: []

  @spec validate_array(term(), map(), String.t()) :: [error()]
  defp validate_array(data, schema, path) do
    if is_list(data) do
      items = Map.get(schema, "items", %{})

      data
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        validate_value(item, items, "#{path}/#{index}")
      end)
    else
      [error(path, "expected array")]
    end
  end

  @spec validate_string(term(), map(), String.t()) :: [error()]
  defp validate_string(data, schema, path) do
    cond do
      not is_binary(data) ->
        [error(path, "expected string")]

      enum = Map.get(schema, "enum") ->
        if data in enum, do: [], else: [error(path, "must be one of #{inspect(enum)}")]

      true ->
        []
    end
  end

  @spec validate_integer(term(), map(), String.t()) :: [error()]
  defp validate_integer(data, schema, path) do
    errors =
      if is_integer(data) do
        []
      else
        [error(path, "expected integer")]
      end

    errors
    |> Kernel.++(min_error(data, Map.get(schema, "minimum"), path))
    |> Kernel.++(max_error(data, Map.get(schema, "maximum"), path))
  end

  @spec min_error(integer(), term(), String.t()) :: [error()]
  defp min_error(data, min, path) when is_integer(min) and data < min, do: [error(path, "must be >= #{min}")]
  defp min_error(_data, _min, _path), do: []

  @spec max_error(integer(), term(), String.t()) :: [error()]
  defp max_error(data, max, path) when is_integer(max) and data > max, do: [error(path, "must be <= #{max}")]
  defp max_error(_data, _max, _path), do: []

  @spec validate_number(term(), map(), String.t()) :: [error()]
  defp validate_number(data, _schema, path) do
    if is_number(data), do: [], else: [error(path, "expected number")]
  end

  @spec validate_boolean(term(), map(), String.t()) :: [error()]
  defp validate_boolean(data, _schema, path) do
    if is_boolean(data), do: [], else: [error(path, "expected boolean")]
  end

  @spec error(String.t(), String.t()) :: error()
  defp error(path, message), do: %{path: path, message: message}
end
