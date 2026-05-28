defmodule Harness.Chat.ToolsTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Tools

  test "build/0 resolves MCP tool names to MFAs" do
    registry = Tools.build()

    assert map_size(registry) > 0
    assert %{module: Harness.ProjectRegistry, function: :list} = registry["project_registry__list"]
  end

  test "schemas/1 returns backend-ready tool maps" do
    registry = Tools.build()

    tool =
      registry
      |> Tools.schemas()
      |> Enum.find(&(&1.name == "project_registry__list"))

    assert %{description: desc, input_schema: schema} = tool
    assert is_binary(desc)
    assert Map.get(schema, "type") || Map.get(schema, :type) == "object"
  end

  test "dispatch/3 decodes atom params from colon-prefixed strings" do
    registry = Tools.build()

    assert {:ok, {:ok, Harness.AgentAdapter.Codex}} =
             Tools.dispatch(registry, "audit_review__default_grader", %{"implementer" => ":claude"})
  end

  test "dispatch/3 returns unknown_tool for missing names" do
    registry = Tools.build()
    assert {:error, {:unknown_tool, "missing__tool"}} = Tools.dispatch(registry, "missing__tool", %{})
  end
end
