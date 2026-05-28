defmodule Harness.Dashboard.MCPRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Harness.Dashboard.Endpoint
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    start_supervised!(Endpoint)
    ProjectRegistry.reset()
    :ok
  end

  describe "GET /harness/mcp/tools" do
    test "returns MCP tool-list JSON from the manifest" do
      conn = request(:get, "/harness/mcp/tools")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      body = Jason.decode!(conn.resp_body)
      assert %{"tools" => tools} = body
      assert is_list(tools)

      assert %{"name" => "project_registry__list", "description" => description, "inputSchema" => schema} =
               Enum.find(tools, &(&1["name"] == "project_registry__list"))

      assert description == "List every registered project, sorted by name."
      assert schema["type"] == "object"
      assert schema["properties"] == %{}
      assert schema["required"] == []
    end
  end

  describe "POST /harness/mcp/call" do
    test "returns 404 for an unknown tool name" do
      conn =
        request(:post, "/harness/mcp/call", %{
          "name" => "missing__tool",
          "arguments" => %{}
        })

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == %{"error" => "unknown_tool", "name" => "missing__tool"}
    end

    test "returns 422 with a specific schema violation" do
      conn =
        request(:post, "/harness/mcp/call", %{
          "name" => "project_registry__lookup",
          "arguments" => %{}
        })

      assert conn.status == 422

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "schema_validation_failed",
               "violations" => [%{"path" => "/name", "message" => "required property is missing"}]
             }
    end

    test "dispatches a manifest tool and returns the JSON-safe result" do
      project = ProjectFixture.from_repo("/tmp/harness-mcp-smoke", name: "mcp-smoke")
      assert :ok = ProjectRegistry.register(project)

      conn =
        request(:post, "/harness/mcp/call", %{
          "name" => "project_registry__list",
          "arguments" => %{}
        })

      assert conn.status == 200

      assert %{"result" => [%{"name" => "mcp-smoke", "source" => ["local", "/tmp/harness-mcp-smoke"]}]} =
               Jason.decode!(conn.resp_body)
    end

    test "dispatches a tool with required arguments" do
      project = ProjectFixture.from_repo("/tmp/harness-mcp-lookup", name: "mcp-lookup")
      assert :ok = ProjectRegistry.register(project)

      conn =
        request(:post, "/harness/mcp/call", %{
          "name" => "project_registry__lookup",
          "arguments" => %{"name" => "mcp-lookup"}
        })

      assert conn.status == 200

      assert %{"result" => ["ok", %{"name" => "mcp-lookup", "source" => ["local", "/tmp/harness-mcp-lookup"]}]} =
               Jason.decode!(conn.resp_body)
    end
  end

  defp request(method, path, body \\ nil) do
    case method do
      :get ->
        method
        |> conn(path)
        |> Endpoint.call([])

      :post ->
        method
        |> conn(path, Jason.encode!(body || %{}))
        |> put_req_header("content-type", "application/json")
        |> Endpoint.call([])
    end
  end
end
