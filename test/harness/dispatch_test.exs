defmodule Harness.DispatchTest do
  use ExUnit.Case, async: true

  alias Harness.Dispatch

  describe "task/4 adapter resolution" do
    test "rejects an unknown adapter before touching the registry" do
      assert {:error, {:unknown_adapter, "bogus"}} =
               Dispatch.task("any-project", "next", "bogus")
    end

    # An unregistered project means adapter resolution already succeeded — so
    # reaching :unknown_project proves the adapter string mapped to a module.
    # This covers delegatable and non-delegatable executors alike, without
    # spawning a run.
    for adapter <- ~w(claude codex cursor grok antigravity pi) do
      test "resolves the #{adapter} adapter (reaches project lookup)" do
        assert {:error, {:unknown_project, "__no_such_project__"}} =
                 Dispatch.task("__no_such_project__", "next", unquote(adapter))
      end
    end

    test "defaults the adapter to claude" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.task("__no_such_project__", "next")
    end
  end

  describe "task/4 project resolution" do
    test "returns unknown_project for an unregistered project" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.task("__no_such_project__", "25", "claude")
    end
  end

  describe "MCP surface" do
    test "dispatch__task is exposed as a flat, JSON-passable tool" do
      tools = Harness.Manifest.mcp_tools()
      tool = Enum.find(tools, &(&1.name == "dispatch__task"))

      assert tool, "dispatch__task should be on the MCP tool surface"

      # Descripex.MCP keys `properties` by atom, `required` by string.
      props = tool.inputSchema.properties
      assert Map.has_key?(props, :project_name)
      assert Map.has_key?(props, :task)
      assert Map.has_key?(props, :adapter)
      assert Map.has_key?(props, :scrub_anthropic_key)

      # Required params are only the two with no default.
      assert Enum.sort(tool.inputSchema.required) == ["project_name", "task"]
    end

    test "excludes struct-arg tools a JSON orchestrator cannot drive" do
      names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)

      for excluded <- ~w(supervisor__start_run batch__run batch__run_pinned batch__dispatch agent_evaluation__compare) do
        refute excluded in names, "#{excluded} must not be on the MCP surface"
      end
    end

    test "the full Elixir/Manifest driver surface still carries the struct-arg modules" do
      modules = Harness.Manifest.modules()

      # The struct tools are excluded from the JSON tool list but remain part of
      # the in-process Elixir driver surface (project_eval / IEx).
      assert Harness.Run.Supervisor in modules
      assert Harness.Batch in modules
      assert function_exported?(Harness.Run.Supervisor, :start_run, 4)
      assert function_exported?(Harness.Batch, :run, 4)
    end
  end
end
