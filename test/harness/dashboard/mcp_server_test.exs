defmodule Harness.Dashboard.MCPServerTest do
  # async: false because tests reset the singleton ProjectRegistry and :result_store env.
  use ExUnit.Case, async: false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Harness.Dashboard.MCPPlug
  alias Harness.Dashboard.MCPServer
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.ResultStoreContract

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

      lookup = Enum.find(tools, &(&1["name"] == "project_registry-list"))
      assert %{"description" => description, "inputSchema" => schema} = lookup
      assert description == "List every registered project, sorted by name."
      assert schema["type"] == "object"
      assert schema["properties"] == %{}
      assert schema["required"] == []

      health = Enum.find(tools, &(&1["name"] == "result_store-aggregate_review_stuck_causes"))
      assert %{"description" => health_description, "inputSchema" => health_schema} = health
      assert health_description =~ "Orchestration-health review_stuck counts"
      assert health_schema["type"] == "object"

      for name <- ~w(
             agents-list
             agents-reviewers
             autonomy-status
             config-list
             config-get
             describe-tools
             describe-tool
           ) do
        assert Enum.any?(tools, &(&1["name"] == name))
      end
    end
  end

  describe "tools/call" do
    test "dispatches a no-arg manifest tool and returns content+isError=false", %{frame: frame} do
      project = ProjectFixture.from_repo("/tmp/harness-mcp-smoke", name: "mcp-smoke")
      assert :ok = ProjectRegistry.register(project)

      request = call_request("project_registry-list", %{})

      assert {:reply, %{"content" => content, "isError" => false}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert [%{"type" => "text", "text" => text}] = content
      assert {:ok, decoded} = Jason.decode(text)
      assert [%{"name" => "mcp-smoke", "source" => ["local", "/tmp/harness-mcp-smoke"]}] = decoded
    end

    test "dispatches a tool with required arguments", %{frame: frame} do
      project = ProjectFixture.from_repo("/tmp/harness-mcp-lookup", name: "mcp-lookup")
      assert :ok = ProjectRegistry.register(project)

      request = call_request("project_registry-lookup", %{"name" => "mcp-lookup"})

      assert {:reply, %{"content" => [%{"text" => text}], "isError" => false}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert {:ok, ["ok", %{"name" => "mcp-lookup", "source" => ["local", "/tmp/harness-mcp-lookup"]}]} =
               Jason.decode(text)
    end

    test "returns JSON-RPC :invalid_params error for an unknown tool", %{frame: frame} do
      request = call_request("missing-tool", %{})

      assert {:error, %Error{code: code, data: data}, ^frame} =
               MCPServer.handle_request(request, frame)

      # MCP protocol -32602 = invalid_params
      assert code == -32_602
      assert data[:message] =~ "missing-tool"
    end

    test "returns isError=true for schema validation failure with per-field path", %{frame: frame} do
      request = call_request("project_registry-lookup", %{})

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
        "params" => %{"name" => "project_registry-list"}
      }

      assert {:reply, %{"content" => _, "isError" => false}, ^frame} =
               MCPServer.handle_request(request, frame)
    end

    test "coerces dispatch-hold interrupt booleans before applying the tool", %{frame: frame} do
      for interrupt <- [true, false, "true", "false", %{"value" => true}, %{"value" => false}] do
        request = call_request("dispatch-hold", %{"run_id" => "__no_such_run__", "interrupt" => interrupt})

        assert {:reply, %{"content" => [%{"text" => text}], "isError" => false}, ^frame} =
                 MCPServer.handle_request(request, frame)

        assert {:ok, ["error", "not_found"]} = Jason.decode(text)
      end
    end

    test "exposes review_stuck cause counts through the result-store MCP tool", %{frame: frame} do
      scope = "mcp-review-stuck-#{System.unique_integer([:positive])}"
      previous_store = Application.get_env(:harness, :result_store)
      Application.put_env(:harness, :result_store, {Memory, scope: scope})

      on_exit(fn ->
        Memory.reset(scope: scope)
        restore_result_store(previous_store)
      end)

      selection_stuck =
        ResultStoreContract.log_record(
          run_id: "mcp-stuck-selection",
          verdict: nil,
          reason:
            {:review_stuck,
             "No cross-family reviewer adapter available: {:reviewer_unavailable, Harness.AgentAdapter.Claude}"},
          reviewer_adapter: nil
        )

      approved = ResultStoreContract.log_record(run_id: "mcp-approved", verdict: :approve, reason: :approved)

      assert :ok = ResultStore.record_run(selection_stuck)
      assert :ok = ResultStore.record_run(approved)

      request = call_request("result_store-aggregate_review_stuck_causes", %{})

      assert {:reply, %{"content" => [%{"text" => text}], "isError" => false}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert {:ok, ["ok", %{"reviewer_unavailable" => 1}]} = Jason.decode(text)
    end

    test "smokes new no-arg operator read tools", %{frame: frame} do
      for name <- ~w(agents-list autonomy-status config-list describe-tools) do
        request = call_request(name, %{})

        assert {:reply, %{"content" => [%{"text" => text}], "isError" => false}, ^frame} =
                 MCPServer.handle_request(request, frame)

        assert {:ok, _decoded} = Jason.decode(text)
      end
    end

    test "schema-validates new one-arg tools", %{frame: frame} do
      request = call_request("config-get", %{})

      assert {:reply, %{"content" => [%{"text" => text}], "isError" => true}, ^frame} =
               MCPServer.handle_request(request, frame)

      assert text =~ "Schema validation failed"
      assert text =~ "#/key"
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
      start_supervised!(
        {MCPServer, transport: {:streamable_http, start: true}, request_timeout: MCPServer.request_timeout_ms()}
      )

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

      plug_opts = plug_opts()
      result = MCPPlug.call(conn, plug_opts)

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

  # Task 296 regression. anubis StreamableHTTP used a hardcoded 30s GenServer.call
  # timeout, killing blocking dispatch tools (await/await_runs/compare) whose own
  # timeout_ms defaults to 30 min.
  describe "blocking tool transport timeout (Task 296)" do
    @blocking_wait_ms 31_000
    @concurrent_wait_ms 1_000
    @read_tool_timeout_ms 250

    setup do
      start_supervised!(
        {MCPServer, transport: {:streamable_http, start: true}, request_timeout: MCPServer.request_timeout_ms()}
      )

      :ok
    end

    test "request_timeout_ms matches the default blocking-tool budget (30 min)" do
      assert MCPServer.request_timeout_ms() == 1_800_000
    end

    @tag timeout: 60_000
    test "dispatch-await_runs blocking past the old 30s ceiling completes over StreamableHTTP" do
      queued_id = "run-mcp-transport-#{System.unique_integer([:positive])}"

      Application.put_env(:harness, :oban_run_job_lookup, fn
        ^queued_id ->
          {:ok,
           %Oban.Job{
             id: 296,
             state: "executing",
             queue: "project_interactive",
             worker: "Harness.Run.Worker",
             args: %{
               "project_name" => "interactive",
               "item_id" => "296",
               "run_id" => queued_id
             }
           }}

        _other ->
          {:error, :not_found}
      end)

      on_exit(fn -> Application.delete_env(:harness, :oban_run_job_lookup) end)

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, response, session_id} =
               mcp_tools_call(
                 "dispatch-await_runs",
                 %{"run_ids" => [queued_id], "timeout_ms" => @blocking_wait_ms},
                 session_id: initialize_mcp_session!()
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms >= @blocking_wait_ms - 500
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2

      assert %{
               "content" => [%{"type" => "text", "text" => text}],
               "isError" => false
             } = response["result"]

      assert {:ok, ["ok", [summary]]} = Jason.decode(text)

      assert summary == %{
               "run_id" => queued_id,
               "state" => "timed_out",
               "reason" => "await_timeout",
               "review_verdict" => "nil"
             }

      assert is_binary(session_id)
    end

    test "read tools respond on the same MCP session while dispatch-await is attached to an in-flight run" do
      queued_id = "run-mcp-concurrent-#{System.unique_integer([:positive])}"
      project_name = "mcp-await-#{System.unique_integer([:positive])}"
      parent = self()
      project = ProjectFixture.from_repo("test/fixtures/sample_roadmap", name: project_name)
      prior_agent_model = Application.get_env(:harness, :agent_model)

      assert :ok = ProjectRegistry.register(project)

      Application.put_env(:harness, :agent_model, codex: "gpt-5.5")

      Application.put_env(:harness, :oban_insert, fn _changeset ->
        {:ok,
         %Oban.Job{
           id: 310,
           conflict?: true,
           state: "executing",
           queue: "project_interactive",
           worker: "Harness.Run.Worker",
           args: %{
             "project_name" => project_name,
             "item_id" => "2",
             "run_id" => queued_id
           }
         }}
      end)

      Application.put_env(:harness, :oban_run_job_lookup, fn
        ^queued_id ->
          send(parent, {:job_lookup, queued_id})

          {:ok,
           %Oban.Job{
             id: 310,
             state: "executing",
             queue: "project_interactive",
             worker: "Harness.Run.Worker",
             args: %{
               "project_name" => project_name,
               "item_id" => "2",
               "run_id" => queued_id
             }
           }}

        _other ->
          {:error, :not_found}
      end)

      on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)
      on_exit(fn -> Application.delete_env(:harness, :oban_run_job_lookup) end)

      on_exit(fn ->
        if prior_agent_model,
          do: Application.put_env(:harness, :agent_model, prior_agent_model),
          else: Application.delete_env(:harness, :agent_model)
      end)

      session_id = initialize_mcp_session!()

      await_task =
        Task.async(fn ->
          mcp_tools_call(
            "dispatch-await",
            %{
              "project_name" => project_name,
              "task" => "2",
              "adapter" => "codex",
              "timeout_ms" => @concurrent_wait_ms
            },
            session_id: session_id
          )
        end)

      assert_receive {:job_lookup, ^queued_id}, @read_tool_timeout_ms

      status_task =
        Task.async(fn ->
          mcp_tools_call("dispatch-status", %{"run_id" => queued_id}, session_id: session_id)
        end)

      case Task.yield(status_task, @read_tool_timeout_ms) || Task.shutdown(status_task, :brutal_kill) do
        {:ok, {:ok, response, ^session_id}} ->
          assert %{
                   "content" => [%{"type" => "text", "text" => text}],
                   "isError" => false
                 } = response["result"]

          assert {:ok, ["ok", %{"run_id" => ^queued_id, "state" => "dispatched"}]} =
                   Jason.decode(text)

        nil ->
          Task.shutdown(await_task, :brutal_kill)
          flunk("dispatch-status did not return while dispatch-await was pending")
      end

      assert {:ok, {:ok, await_response, ^session_id}} = Task.yield(await_task, @concurrent_wait_ms * 2)

      assert %{
               "content" => [%{"type" => "text", "text" => await_text}],
               "isError" => false
             } = await_response["result"]

      assert {:ok, ["ok", %{"run_id" => ^queued_id, "state" => "timed_out", "timeout_ms" => @concurrent_wait_ms}]} =
               Jason.decode(await_text)
    end
  end

  defp plug_opts do
    MCPPlug.init(
      server: MCPServer,
      request_timeout: MCPServer.request_timeout_ms()
    )
  end

  defp initialize_mcp_session! do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "harness-test", "version" => "1.0.0"}
        }
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")

    result = MCPPlug.call(conn, plug_opts())
    assert result.status == 200

    [session_id] = Plug.Conn.get_resp_header(result, "mcp-session-id")

    initialized_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{}
      })

    initialized_conn =
      :post
      |> Plug.Test.conn("/", initialized_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)

    initialized_result = MCPPlug.call(initialized_conn, plug_opts())
    assert initialized_result.status == 202

    session_id
  end

  @spec mcp_tools_call(String.t(), map(), keyword()) :: {:ok, map(), String.t()} | no_return()
  defp mcp_tools_call(name, arguments, opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)

    result = MCPPlug.call(conn, plug_opts())
    assert result.status == 200

    assert {:ok, response} = Jason.decode(result.resp_body)
    {:ok, response, session_id}
  end

  defp call_request(name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
  end

  defp restore_result_store(nil), do: Application.delete_env(:harness, :result_store)
  defp restore_result_store(store), do: Application.put_env(:harness, :result_store, store)
end
