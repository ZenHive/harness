defmodule Harness.Chat.SchemaTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Schema

  test "accepts data matching a typed object schema" do
    schema = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}, "count" => %{"type" => "integer"}}
    }

    assert :ok = Schema.validate(%{"name" => "harness", "count" => 3}, schema)
  end

  test "rejects missing required fields" do
    schema = %{"type" => "object", "required" => ["selector"], "properties" => %{}}

    assert {:error, errors} = Schema.validate(%{}, schema)
    assert Enum.any?(errors, &(&1.message == "is required"))
  end

  test "rejects wrong primitive types" do
    schema = %{"type" => "object", "properties" => %{"selector" => %{"type" => "string"}}}

    assert {:error, _} = Schema.validate(%{"selector" => 123}, schema)
  end

  test "rejects additional properties when disabled" do
    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{}
    }

    assert {:error, errors} = Schema.validate(%{"extra" => true}, schema)
    assert Enum.any?(errors, &String.contains?(&1.message, "additional property"))
  end

  test "validates arrays and integer bounds" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 10}
      }
    }

    assert :ok = Schema.validate(%{"tags" => ["a"], "limit" => 5}, schema)
    assert {:error, _} = Schema.validate(%{"tags" => [1], "limit" => 0}, schema)
  end

  test "validates string enums" do
    schema = %{
      "type" => "object",
      "properties" => %{"status" => %{"type" => "string", "enum" => ["on", "off"]}}
    }

    assert :ok = Schema.validate(%{"status" => "on"}, schema)
    assert {:error, _} = Schema.validate(%{"status" => "maybe"}, schema)
  end

  test "validates booleans and numbers" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "enabled" => %{"type" => "boolean"},
        "ratio" => %{"type" => "number"}
      }
    }

    assert :ok = Schema.validate(%{"enabled" => true, "ratio" => 1.5}, schema)
    assert {:error, _} = Schema.validate(%{"enabled" => "yes", "ratio" => "nope"}, schema)
  end
end
