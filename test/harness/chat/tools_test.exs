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

  # Review fix #9: an explicitly-passed `null` for an optional param with a
  # default coalesces to that default (LLM callers routinely emit null for
  # unset params) rather than being decoded as a literal nil value. Guards
  # against a regression that would forward nil and break the function guard.
  test "dispatch/3 coalesces an explicit null for a defaulted param to its default" do
    registry = Tools.build()

    # `filters` defaults to []; a nil forwarded instead would fail the
    # `when is_list(filters)` guard. The outer {:ok, _} is dispatch's success
    # wrapper, the inner is list_run_records's own {:ok, list} return.
    assert {:ok, {:ok, with_null}} =
             Tools.dispatch(registry, "result_store__list_run_records", %{"filters" => nil})

    assert is_list(with_null)

    # Absent key resolves to the same default — the present-vs-absent branch
    # must not diverge for a defaulted param.
    assert {:ok, {:ok, absent}} =
             Tools.dispatch(registry, "result_store__list_run_records", %{})

    assert is_list(absent)
  end
end
