defmodule Harness.Dashboard.MCPPlugTest do
  # async: false — drives the real MCP tool dispatch and toggles the global
  # `:oban_run_job_lookup` app-env seam to make a run block deterministically.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Harness.Dashboard.MCPPlug
  alias Harness.Dashboard.MCPServer

  @session_header "mcp-session-id"

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

  defp post_conn(message, accept) do
    :post
    |> conn("/harness/mcp")
    |> put_req_header("accept", accept)
    |> put_req_header(@session_header, "sess-1")
    |> Map.put(:body_params, message)
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

    # The client-disconnect branch (chunk/2 -> {:error, :closed} -> shutdown task +
    # halt) cannot be exercised through Plug.Test, whose adapter never fails a chunk
    # write; it is covered by the end-to-end check against the live :4018 endpoint.
  end
end
