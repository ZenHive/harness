defmodule Harness.Dashboard.MCPPlugTest do
  # async: false — drives the real MCP tool dispatch and toggles the global
  # `:oban_run_job_lookup` app-env seam to make a run block deterministically.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Harness.Dashboard.MCPPlug
  alias Harness.Dashboard.MCPServer
  alias Plug.Adapters.Test.Conn

  @session_header "mcp-session-id"

  defmodule FailingChunkAdapter do
    @moduledoc false
    @behaviour Plug.Conn.Adapter

    defdelegate send_resp(state, status, headers, body), to: Conn
    defdelegate send_file(state, status, headers, path, offset, length), to: Conn
    defdelegate send_chunked(state, status, headers), to: Conn
    defdelegate read_req_body(state, opts), to: Conn
    defdelegate inform(state, status, headers), to: Conn
    defdelegate upgrade(state, protocol, opts), to: Conn
    defdelegate push(state, path, headers), to: Conn
    defdelegate get_peer_data(state), to: Conn
    defdelegate get_sock_data(state), to: Conn
    defdelegate get_ssl_data(state), to: Conn
    defdelegate get_http_protocol(state), to: Conn

    def chunk(_state, _body), do: {:error, :closed}
  end

  setup do
    # Capture-and-restore (not blind delete) so a value another test/config set
    # survives this test's mutation of the global seam.
    previous = Application.fetch_env(:harness, :oban_run_job_lookup)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:harness, :oban_run_job_lookup, value)
        :error -> Application.delete_env(:harness, :oban_run_job_lookup)
      end
    end)

    :ok
  end

  # `dispatch-await_runs` against an unknown run id settles immediately (:not_found
  # counts as complete), giving a fast, dependency-free tool call for the path tests.
  defp tools_call(run_ids, timeout_ms) do
    %{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "dispatch-await_runs",
        "arguments" => %{"run_ids" => run_ids, "timeout_ms" => timeout_ms}
      }
    }
  end

  defp initialize_message do
    %{
      "jsonrpc" => "2.0",
      "id" => "init-1",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "harness-test", "version" => "1.0.0"}
      }
    }
  end

  defp post_conn(message, accept) do
    :post
    |> conn("/harness/mcp")
    |> put_req_header("accept", accept)
    |> put_req_header(@session_header, "sess-1")
    |> Map.put(:body_params, message)
  end

  defp failing_chunk_conn(conn) do
    %{conn | adapter: {FailingChunkAdapter, elem(conn.adapter, 1)}}
  end

  defp call(conn, opts \\ []) do
    MCPPlug.call(conn, MCPPlug.init([server: MCPServer] ++ opts))
  end

  # Mark a run id as in-flight so `Dispatch.await_runs` blocks until its deadline.
  defp stub_executing(run_id) do
    Application.put_env(:harness, :oban_run_job_lookup, fn
      ^run_id ->
        {:ok,
         %Oban.Job{
           id: 1,
           state: "executing",
           queue: "project_interactive",
           worker: "Harness.Run.Worker",
           args: %{"project_name" => "interactive", "item_id" => "2", "run_id" => run_id}
         }}

      _other ->
        {:error, :not_found}
    end)
  end

  # The terminal SSE frame is `... event: message\ndata: <json>\n\n`. Pull the JSON.
  defp last_event_payload(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> List.last()
    |> String.replace_prefix("data: ", "")
    |> Jason.decode!()
  end

  # A tool result is wrapped as `result.content[0].text`, itself a JSON string
  # `["ok", [<summary maps>]]`. Unwrap to the summary list.
  defp tool_summaries(jsonrpc_response) do
    [%{"text" => text} | _] = jsonrpc_response["result"]["content"]
    [_status, summaries] = Jason.decode!(text)
    summaries
  end

  describe "tools/call without SSE (Accept: application/json)" do
    test "answers synchronously as a single JSON body" do
      conn = call(post_conn(tools_call(["__no_such_run__"], 1_000), "application/json"))

      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      decoded = Jason.decode!(conn.resp_body)
      assert decoded["id"] == "req-1"
      assert [summary] = tool_summaries(decoded)
      assert summary["run_id"] == "__no_such_run__"
      assert summary["state"] == "not_found"
    end

    test "returns a JSON-RPC error for an unknown tool" do
      message = %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "method" => "tools/call",
        "params" => %{"name" => "__unknown_tool__", "arguments" => %{}}
      }

      conn = call(post_conn(message, "application/json"))

      assert conn.status == 200
      assert %{"error" => %{"code" => -32_602}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "tools/call with SSE (Accept: text/event-stream)" do
    test "streams the result as a terminal SSE message event" do
      conn = call(post_conn(tools_call(["__no_such_run__"], 1_000), "text/event-stream"))

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "event: message"

      payload = last_event_payload(conn.resp_body)
      assert payload["id"] == "req-1"
      assert payload["result"]
    end

    test "emits keepalive frames before the result while the tool blocks" do
      run_id = "run-blocking-keepalive"
      stub_executing(run_id)

      conn = call(post_conn(tools_call([run_id], 150), "text/event-stream"), keepalive_interval_ms: 20)

      assert conn.status == 200
      # At least one keepalive comment frame is emitted *before* the terminal
      # message event — compare byte offsets so a regression that only emitted
      # keepalives after the result (or none) fails deterministically.
      keepalive_idx = conn.resp_body |> :binary.match(": keepalive") |> elem(0)
      message_idx = conn.resp_body |> :binary.match("event: message") |> elem(0)
      assert keepalive_idx < message_idx

      payload = last_event_payload(conn.resp_body)
      assert [summary] = tool_summaries(payload)
      assert summary["state"] == "timed_out"
      assert summary["reason"] == "await_timeout"
      assert summary["run_id"] == run_id
    end

    test "streams a JSON-RPC error returned by the server" do
      message = %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "method" => "tools/call",
        "params" => %{"name" => "__unknown_tool__", "arguments" => %{}}
      }

      conn = call(post_conn(message, "text/event-stream"))

      assert conn.status == 200
      assert %{"error" => %{"code" => -32_602}} = last_event_payload(conn.resp_body)
    end

    test "returns an internal error when the supervised tool task exits" do
      Application.put_env(:harness, :oban_run_job_lookup, fn _run_id -> exit(:lookup_crashed) end)

      conn = call(post_conn(tools_call(["crash"], 1_000), "text/event-stream"))

      assert conn.status == 200
      assert %{"error" => %{"code" => -32_603}} = last_event_payload(conn.resp_body)
    end

    test "halts when the client disconnects before a keepalive" do
      run_id = "run-disconnected-keepalive"
      stub_executing(run_id)

      conn =
        [run_id]
        |> tools_call(1_000)
        |> post_conn("text/event-stream")
        |> failing_chunk_conn()
        |> call(keepalive_interval_ms: 20)

      assert conn.halted
    end

    test "returns the connection when the terminal event cannot be written" do
      conn =
        ["__no_such_run__"]
        |> tools_call(1_000)
        |> post_conn("text/event-stream")
        |> failing_chunk_conn()
        |> call()

      assert conn.status == 200
      assert conn.state == :chunked
    end
  end

  describe "protocol errors" do
    test "delegates session initialization to the streamable HTTP plug" do
      start_supervised!(
        {MCPServer, transport: {:streamable_http, start: true}, request_timeout: MCPServer.request_timeout_ms()}
      )

      conn =
        :post
        |> conn("/harness/mcp", Jason.encode!(initialize_message()))
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, @session_header)
      assert is_binary(session_id)
    end

    test "accepts initialized notifications and tools/list on direct POST" do
      initialized = call(post_conn(%{"method" => "notifications/initialized"}, "application/json"))

      tools_list =
        call(post_conn(%{"jsonrpc" => "2.0", "id" => "req-1", "method" => "tools/list"}, "application/json"))

      assert initialized.status == 202
      assert %{"result" => %{"tools" => tools}} = Jason.decode!(tools_list.resp_body)
      assert is_list(tools)
    end

    test "returns a parse error for malformed JSON" do
      conn =
        :post
        |> conn("/harness/mcp", "{")
        |> put_req_header("accept", "application/json")
        |> put_req_header(@session_header, "sess-1")
        |> call()

      assert conn.status == 200
      assert %{"error" => %{"code" => -32_700}} = Jason.decode!(conn.resp_body)
    end

    test "returns method-not-found and invalid-request errors" do
      method_not_found = call(post_conn(%{"id" => "req-1", "method" => "unknown"}, "application/json"))
      invalid_request = call(post_conn(%{"jsonrpc" => "2.0"}, "application/json"))

      assert %{"error" => %{"code" => -32_601}} = Jason.decode!(method_not_found.resp_body)
      assert %{"error" => %{"code" => -32_600}} = Jason.decode!(invalid_request.resp_body)
    end

    test "delegates non-POST requests to the streamable HTTP plug" do
      start_supervised!(
        {MCPServer, transport: {:streamable_http, start: true}, request_timeout: MCPServer.request_timeout_ms()}
      )

      conn = call(conn(:patch, "/harness/mcp"))

      assert conn.status == 405
    end
  end

  describe "Origin guard" do
    test "refuses a foreign Origin before direct tool dispatch" do
      parent = self()

      Application.put_env(:harness, :oban_run_job_lookup, fn run_id ->
        send(parent, {:tool_dispatched, run_id})
        {:error, :not_found}
      end)

      conn =
        ["must-not-dispatch"]
        |> tools_call(1_000)
        |> post_conn("application/json")
        |> put_req_header("origin", "https://attacker.example")
        |> call()

      assert conn.status == 403
      assert conn.halted
      refute_received {:tool_dispatched, _run_id}
    end

    test "refuses a foreign Origin before session creation" do
      conn =
        :post
        |> conn("/harness/mcp", Jason.encode!(initialize_message()))
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://attacker.example")
        |> call()

      assert conn.status == 403
      assert conn.halted
      assert get_resp_header(conn, @session_header) == []
    end

    test "serves loopback Origins" do
      for origin <- [
            "http://localhost:4018",
            "http://worker.localhost:4018",
            "http://127.0.0.1:4018",
            "http://[::1]:4018"
          ] do
        conn =
          %{"jsonrpc" => "2.0", "id" => "req-1", "method" => "ping"}
          |> post_conn("application/json")
          |> put_req_header("origin", origin)
          |> call()

        assert conn.status == 200
      end
    end

    test "serves a request with no Origin" do
      conn = call(post_conn(%{"jsonrpc" => "2.0", "id" => "req-1", "method" => "ping"}, "application/json"))

      assert conn.status == 200
    end

    test "refuses a null or non-http Origin" do
      for origin <- ["null", "file://localhost"] do
        conn =
          %{"jsonrpc" => "2.0", "id" => "req-1", "method" => "ping"}
          |> post_conn("application/json")
          |> put_req_header("origin", origin)
          |> call()

        assert conn.status == 403
        assert conn.halted
      end
    end

    test "refuses a foreign Origin on the non-POST anubis path" do
      conn =
        :get
        |> conn("/harness/mcp")
        |> put_req_header("origin", "https://attacker.example")
        |> call()

      assert conn.status == 403
      assert conn.halted
    end
  end
end
