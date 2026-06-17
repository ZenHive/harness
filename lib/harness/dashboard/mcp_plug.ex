defmodule Harness.Dashboard.MCPPlug do
  @moduledoc """
  Streamable HTTP boundary for harness's MCP tools.

  Session creation stays with `anubis_mcp`, while initialized tool requests run
  in the Plug request process. That keeps a long `dispatch-await` from occupying
  anubis's per-session single-flight queue and starving read-only tool calls.
  """

  @behaviour Plug

  import Plug.Conn

  alias Anubis.MCP.Error
  alias Anubis.MCP.Message
  alias Anubis.Server.Frame
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: AnubisPlug
  alias Anubis.SSE.Streaming
  alias Harness.Dashboard.MCPServer

  require Logger

  @default_session_header "mcp-session-id"
  @read_body_length 1_000_000

  # A blocking `tools/call` (await/await_runs/compare can wait up to 30 min) writes
  # nothing to the socket while it polls, so the MCP client's idle/read timeout
  # tears the connection down and surfaces a bare transport error — swallowing the
  # tool's own structured `:timed_out` envelope. When the client accepts SSE we run
  # the tool in a supervised task and emit `: keepalive` comment frames on this
  # cadence, keeping the connection warm until the real result is streamed back.
  @default_keepalive_interval_ms 5_000
  @keepalive_frame ": keepalive\n\n"
  @tool_task_supervisor Harness.Chat.TaskSupervisor

  @impl Plug
  def init(opts) do
    %{
      anubis: AnubisPlug.init(opts),
      session_header: Keyword.get(opts, :session_header, @default_session_header),
      keepalive_interval_ms: Keyword.get(opts, :keepalive_interval_ms, @default_keepalive_interval_ms)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, %{session_header: session_header} = opts) do
    if get_req_header(conn, session_header) == [] do
      AnubisPlug.call(conn, opts.anubis)
    else
      direct_post(conn, opts)
    end
  end

  def call(conn, opts), do: AnubisPlug.call(conn, opts.anubis)

  @spec direct_post(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp direct_post(conn, opts) do
    case fetch_message(conn) do
      {:ok, message} -> handle_direct_message(conn, opts, message)
      :error -> send_jsonrpc_error(conn, Error.protocol(:parse_error), nil)
    end
  end

  # The dashboard endpoint runs `Plug.Parsers` (`:json`) before this plug, so the
  # raw body is already drained — re-reading it here yields `""` and a bogus parse
  # error. Trust the parsed `conn.body_params` map; fall back to `read_body/2` only
  # when this plug is mounted without an upstream JSON parser.
  @spec fetch_message(Plug.Conn.t()) :: {:ok, map()} | :error
  defp fetch_message(%Plug.Conn{body_params: %{} = params}) when not is_struct(params) and map_size(params) > 0 do
    {:ok, params}
  end

  defp fetch_message(conn) do
    with {:ok, body, _conn} <- read_body(conn, length: @read_body_length),
         {:ok, message} <- Jason.decode(body) do
      {:ok, message}
    else
      _error -> :error
    end
  end

  @spec handle_direct_message(Plug.Conn.t(), map(), map()) :: Plug.Conn.t()
  defp handle_direct_message(conn, _opts, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  # `tools/call` is the only blocking method (await/await_runs/compare). When the
  # client accepts SSE, stream it with keepalives so a long wait survives the
  # client's idle timeout; otherwise answer synchronously as a single JSON body.
  defp handle_direct_message(conn, opts, %{"id" => request_id, "method" => "tools/call"} = message) do
    if wants_sse?(conn) do
      stream_tool_call(conn, opts, request_id, message)
    else
      respond_sync(conn, opts.session_header, request_id, message)
    end
  end

  defp handle_direct_message(conn, opts, %{"id" => request_id, "method" => method} = message)
       when method in ["ping", "tools/list"] do
    respond_sync(conn, opts.session_header, request_id, message)
  end

  defp handle_direct_message(conn, _opts, %{"id" => request_id}) do
    send_jsonrpc_error(conn, Error.protocol(:method_not_found), request_id)
  end

  defp handle_direct_message(conn, _opts, _message) do
    send_jsonrpc_error(conn, Error.protocol(:invalid_request), nil)
  end

  @spec respond_sync(Plug.Conn.t(), String.t(), String.t() | integer(), map()) :: Plug.Conn.t()
  defp respond_sync(conn, session_header, request_id, message) do
    {:ok, frame} = MCPServer.init(%{}, %Frame{})

    case MCPServer.handle_request(message, frame) do
      {:reply, response, %Frame{}} ->
        send_jsonrpc_response(conn, session_header, request_id, response)

      {:error, %Error{} = error, %Frame{}} ->
        send_jsonrpc_error(conn, error, request_id)
    end
  end

  # Run the tool in a supervised (nolink, so a tool crash can't take down the Bandit
  # request process) task while emitting keepalive frames, then stream the real
  # JSON-RPC result as the terminal SSE `message` event.
  @spec stream_tool_call(Plug.Conn.t(), map(), String.t() | integer(), map()) :: Plug.Conn.t()
  defp stream_tool_call(conn, opts, request_id, message) do
    {:ok, frame} = MCPServer.init(%{}, %Frame{})
    task = Task.Supervisor.async_nolink(@tool_task_supervisor, fn -> MCPServer.handle_request(message, frame) end)

    conn
    |> maybe_add_session_header(opts.session_header)
    |> Streaming.prepare_connection()
    |> stream_until_settled(task, opts.keepalive_interval_ms, request_id)
  end

  @spec stream_until_settled(Plug.Conn.t(), Task.t(), pos_integer(), String.t() | integer()) :: Plug.Conn.t()
  defp stream_until_settled(conn, task, interval_ms, request_id) do
    case Task.yield(task, interval_ms) do
      {:ok, {:reply, response, %Frame{}}} ->
        finish_stream(conn, Message.build_response(response, request_id))

      {:ok, {:error, %Error{} = error, %Frame{}}} ->
        finish_stream(conn, Error.build_json_rpc(error, request_id))

      {:exit, reason} ->
        Logger.warning("MCP tool task exited: #{inspect(reason)}")
        internal = Error.protocol(:internal_error, %{message: "tool crashed"})
        finish_stream(conn, Error.build_json_rpc(internal, request_id))

      nil ->
        case chunk(conn, @keepalive_frame) do
          {:ok, conn} ->
            stream_until_settled(conn, task, interval_ms, request_id)

          {:error, _closed} ->
            # Client gave up; the run keeps going and stays observable via dispatch-status.
            Task.shutdown(task, :brutal_kill)
            halt(conn)
        end
    end
  end

  @spec finish_stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp finish_stream(conn, payload) do
    case Streaming.send_event(conn, Jason.encode!(payload), 0) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  @spec wants_sse?(Plug.Conn.t()) :: boolean()
  defp wants_sse?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  @spec send_jsonrpc_response(Plug.Conn.t(), String.t(), String.t() | integer(), map()) :: Plug.Conn.t()
  defp send_jsonrpc_response(conn, session_header, request_id, response) do
    conn
    |> put_resp_content_type("application/json")
    |> maybe_add_session_header(session_header)
    |> send_resp(200, Jason.encode!(Message.build_response(response, request_id)))
  end

  @spec send_jsonrpc_error(Plug.Conn.t(), Error.t(), String.t() | integer() | nil) :: Plug.Conn.t()
  defp send_jsonrpc_error(conn, error, request_id) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Error.build_json_rpc(error, request_id)))
  end

  @spec maybe_add_session_header(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp maybe_add_session_header(conn, session_header) do
    case get_req_header(conn, session_header) do
      [session_id | _] -> put_resp_header(conn, session_header, session_id)
      [] -> conn
    end
  end
end
