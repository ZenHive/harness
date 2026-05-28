defmodule Harness.Dashboard.MCPServerTest do
  use ExUnit.Case, async: false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
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

    test "returns isError=true for schema validation failure with per-field path", %{frame: frame} do
      request = call_request("project_registry__lookup", %{})

      assert {:reply, %{"content" => [%{"text" => text}], "isError" => true}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert text =~ "Schema validation failed"
      # Now that Schema.validate handles atom-keyed schemas, the violation
      # carries the per-field path instead of a generic "#" from the
      # build_apply_args fallback.
      assert text =~ "#/name"
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

  describe "non-tool methods (anubis catch-all fallthrough)" do
    test "delegates `ping` to anubis's default handler without crashing", %{frame: frame} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 99,
        "method" => "ping",
        "params" => %{}
      }

      # We only assert that the call reaches anubis's default handler and
      # returns a tuple — exact response shape is owned by anubis. Catches
      # regressions if the @before_compile catch-all shape ever shifts.
      assert is_tuple(MCPServer.handle_request(request, frame))
    end
  end

  # Task 83 regression. Bug: `transport: :streamable_http` alone made anubis
  # fall through to `Application.get_env(:phoenix, :serve_endpoints)` to decide
  # whether to actually start (see `should_start?/1` in
  # `deps/anubis_mcp/lib/anubis/server/supervisor.ex`). That flag is `false`
  # under `iex -S mix` (harness is not a `phx.server` app), so the supervisor
  # returned `:ignore`, no `:persistent_term` was stored, and every MCP request
  # crashed on `:persistent_term.get/1` with `:badarg`. Fixed in
  # `lib/harness/application.ex` by passing `start: true` on the transport opts.
  describe "supervised streamable_http transport (Task 83)" do
    setup do
      start_supervised!({MCPServer, transport: {:streamable_http, start: true}})
      :ok
    end

    test "stores the session_config persistent_term so the Plug can resolve runtime config" do
      assert %{server_module: MCPServer, registry_mod: _, transport: _} =
               :persistent_term.get({Anubis.Server.Supervisor, MCPServer, :session_config})
    end

    test "initialize from claude-code 2.1.153 (protocol 2025-11-25) returns 200 with the harness tools capability" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "claude-code", "version" => "2.1.153"}
          }
        })

      conn =
        :post
        |> Plug.Test.conn("/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json")

      plug_opts = StreamableHTTPPlug.init(server: MCPServer)
      result = StreamableHTTPPlug.call(conn, plug_opts)

      assert result.status == 200
      assert [session_id] = Plug.Conn.get_resp_header(result, "mcp-session-id")
      assert is_binary(session_id) and session_id != ""

      assert {:ok, response} = Jason.decode(result.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 0

      assert %{
               "protocolVersion" => "2025-11-25",
               "serverInfo" => %{"name" => "harness", "version" => "0.1.0"},
               "capabilities" => %{"tools" => _}
             } = response["result"]
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
