defmodule Harness.ResponseSchemaTest do
  use ExUnit.Case, async: true

  alias Harness.ResponseSchema

  test "strict objects require every property, including nullable properties" do
    properties = %{"name" => %{"type" => "string"}, "optional" => %{"type" => ["string", "null"]}}
    schema = ResponseSchema.object(properties)
    assert schema["properties"] == properties
    assert Enum.sort(schema["required"]) == ["name", "optional"]
    assert schema["additionalProperties"] == false
    assert ResponseSchema.object(%{})["required"] == []
    assert ResponseSchema.array(schema) == %{"type" => "array", "items" => schema}
  end

  test "both provider schemas retain strict nested objects and their distinct contracts" do
    insights = Harness.Insights.ResponseSchema.schema()
    maintenance = Harness.Maintenance.ResponseSchema.schema()
    assert Enum.sort(insights["required"]) == ["findings", "read"]
    assert Enum.sort(maintenance["required"]) == ["findings", "partial_evidence", "publication_safe", "rationale"]

    for schema <- [insights, maintenance] do
      assert_strict_objects(schema)
    end

    assert get_in(insights, ["properties", "findings", "items", "properties", "citations", "type"]) == "array"
    assert get_in(maintenance, ["properties", "findings", "items", "properties", "blocked", "type"]) == "boolean"
  end

  defp assert_strict_objects(%{"type" => "object", "properties" => properties} = schema) do
    assert schema["additionalProperties"] == false
    assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(properties))
    Enum.each(Map.values(properties), &assert_strict_objects/1)
  end

  defp assert_strict_objects(map) when is_map(map), do: Enum.each(Map.values(map), &assert_strict_objects/1)
  defp assert_strict_objects(list) when is_list(list), do: Enum.each(list, &assert_strict_objects/1)
  defp assert_strict_objects(_), do: :ok
end
