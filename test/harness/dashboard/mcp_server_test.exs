defmodule Harness.Dashboard.MCPServerTest do
  use ExUnit.Case, async: false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Harness.Dashboard.MCPServer
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    ProjectRegistry.reset()
    {:ok, frame} = MCPServer.init(%{}, %Frame{})
    {:ok, frame: frame}
  end

  describe "tools/list" do
    test "lists every descripex-annotated manifest tool with JSON Schema", %{frame: frame} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      }

      assert {:reply, %{"tools" => tools}, ^frame} = MCPServer.handle_request(request, frame)
      assert is_list(tools)

      lookup = Enum.find(tools, &(&1["name"] == "project_registry__list"))
      assert %{"description" => description, "inputSchema" => schema} = lookup
      assert description == "List every registered project, sorted by name."
      assert schema["type"] == "object"
      assert schema["properties"] == %{}
      assert schema["required"] == []
    end
  end

  describe "tools/call" do
    test "dispatches a no-arg manifest tool and returns content+isError=false", %{frame: frame} do
      project = ProjectFixture.from_repo("/tmp/harness-mcp-smoke", name: "mcp-smoke")
      assert :ok = ProjectRegistry.register(project)

      request = call_request("project_registry__list", %{})

      assert {:reply, %{"content" => content, "isError" => false}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert [%{"type" => "text", "text" => text}] = content
      assert {:ok, decoded} = Jason.decode(text)
      assert [%{"name" => "mcp-smoke", "source" => ["local", "/tmp/harness-mcp-smoke"]}] = decoded
    end

    test "dispatches a tool with required arguments", %{frame: frame} do
      project = ProjectFixture.from_repo("/tmp/harness-mcp-lookup", name: "mcp-lookup")
      assert :ok = ProjectRegistry.register(project)

      request = call_request("project_registry__lookup", %{"name" => "mcp-lookup"})

      assert {:reply, %{"content" => [%{"text" => text}], "isError" => false}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert {:ok, ["ok", %{"name" => "mcp-lookup", "source" => ["local", "/tmp/harness-mcp-lookup"]}]} =
               Jason.decode(text)
    end

    test "returns JSON-RPC :invalid_params error for an unknown tool", %{frame: frame} do
      request = call_request("missing__tool", %{})

      assert {:error, %Error{code: code, data: data}, ^frame} =
               MCPServer.handle_request(request, frame)

      # MCP protocol -32602 = invalid_params
      assert code == -32_602
      assert data[:message] =~ "missing__tool"
    end

    test "returns isError=true for schema validation failure", %{frame: frame} do
      request = call_request("project_registry__lookup", %{})

      assert {:reply, %{"content" => [%{"text" => text}], "isError" => true}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert text =~ "Schema validation failed"
    end

    test "treats a missing arguments key as an empty map", %{frame: frame} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/call",
        "params" => %{"name" => "project_registry__list"}
      }

      assert {:reply, %{"content" => _, "isError" => false}, ^frame} =
               MCPServer.handle_request(request, frame)
    end
  end

  defp call_request(name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
  end
end
