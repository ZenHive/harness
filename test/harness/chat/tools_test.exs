defmodule Harness.Chat.ToolsTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Tools

  test "build/0 resolves MCP tool names to MFAs" do
    registry = Tools.build()

    assert map_size(registry) > 0
    assert %{module: Harness.ProjectRegistry, function: :list} = registry["project_registry-list"]
  end

  test "schemas/1 returns backend-ready tool maps" do
    registry = Tools.build()

    tool =
      registry
      |> Tools.schemas()
      |> Enum.find(&(&1.name == "project_registry-list"))

    assert %{description: desc, input_schema: schema} = tool
    assert is_binary(desc)
    assert Map.get(schema, "type") || Map.get(schema, :type) == "object"
  end

  test "dispatch/3 decodes atom params from colon-prefixed strings" do
    registry = Tools.build()

    assert {:ok, {:ok, Harness.AgentAdapter.Codex}} =
             Tools.dispatch(registry, "audit_review-default_grader", %{"implementer" => ":claude"})
  end

  test "dispatch/3 returns unknown_tool for missing names" do
    registry = Tools.build()
    assert {:error, {:unknown_tool, "missing-tool"}} = Tools.dispatch(registry, "missing-tool", %{})
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
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => nil})

    assert is_list(with_null)

    # Absent key resolves to the same default — the present-vs-absent branch
    # must not diverge for a defaulted param.
    assert {:ok, {:ok, absent}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{})

    assert is_list(absent)
  end

  test "tool names use the single Manifest delimiter (not '__') so client namespacing produces only one '__'" do
    delim = Harness.Manifest.tool_name_delimiter()
    assert delim == "-"

    registry = Tools.build()
    names = Map.keys(registry)

    assert "dispatch-task" in names
    assert "roadmap-list" in names
    assert "result_store-list_run_records" in names

    # Core fix: no tool name contains the old group__action joiner.
    # After a client namespaces as <server>__<tool>, qualified has "__" exactly once.
    for name <- names do
      refute name =~ "__",
             "tool name #{inspect(name)} must not contain '__' (would become double after client ns)"
    end

    # Simulate client namespacing (as grok and strict MCP clients do); only one "__".
    sample = "dispatch-task"
    qualified = "harness__" <> sample
    assert qualified == "harness__dispatch-task"
    assert length(Regex.scan(~r/__/, qualified)) == 1
  end

  test "dispatch/3 translates JSON-shaped (string-keyed map) filters for result_store-list_run_records, atomizing known keys and ignoring unknowns" do
    registry = Tools.build()

    # Documented keys only (run_id, batch_id, agent, adapter, verdict, project_name) — must succeed and yield a list.
    assert {:ok, {:ok, list1}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => %{"run_id" => "r-123"}})

    assert is_list(list1)

    # Mix of documented + unknown keys: unknowns ignored (no crash, no poisoning of good keys).
    assert {:ok, {:ok, list2}} =
             Tools.dispatch(
               registry,
               "result_store-list_run_records",
               %{"filters" => %{"run_id" => "r-123", "project_name" => "harness", "bogus" => true, "extra" => 1}}
             )

    assert is_list(list2)

    # Empty map (no filters) also accepted.
    assert {:ok, {:ok, list3}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => %{}})

    assert is_list(list3)
  end
end
