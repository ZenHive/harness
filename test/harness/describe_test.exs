defmodule Harness.DescribeTest do
  use ExUnit.Case, async: true

  alias Harness.Describe

  test "tools/0 lists the MCP catalog by name and description" do
    names = Enum.map(Describe.tools(), & &1.name)

    assert "project_registry-list" in names
    assert "describe-tools" in names
  end

  test "tool/1 returns the full schema for one MCP tool" do
    assert {:ok,
            %{
              name: "agents-list",
              description: description,
              params: [],
              returns: returns
            }} = Describe.tool("agents-list")

    assert description =~ "List harness agent"
    assert is_map(returns)
  end

  test "tool/1 reports an unknown tool" do
    assert {:error, {:unknown_tool, "missing-tool"}} = Describe.tool("missing-tool")
  end

  test "tool/1 advertises languages and warm_paths as typed arrays" do
    assert {:ok, %{params: params}} = Describe.tool("dispatch-register_project")

    languages = Enum.find(params, &(&1.name == "languages"))
    assert languages.schema["type"] == "array"
    assert languages.schema["items"] == %{"type" => "string"}

    warm_paths = Enum.find(params, &(&1.name == "warm_paths"))
    assert warm_paths.schema["type"] == "array"
    assert warm_paths.schema["items"] == %{"type" => "string"}
  end
end
