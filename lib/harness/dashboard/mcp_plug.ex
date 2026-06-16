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
  alias Harness.Dashboard.MCPServer

  @default_session_header "mcp-session-id"
  @read_body_length 1_000_000

  @impl Plug
  def init(opts) do
    %{
      anubis: AnubisPlug.init(opts),
      session_header: Keyword.get(opts, :session_header, @default_session_header)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, %{session_header: session_header} = opts) do
    if get_req_header(conn, session_header) == [] do
      AnubisPlug.call(conn, opts.anubis)
    else
      direct_post(conn, session_header)
    end
  end

  def call(conn, opts), do: AnubisPlug.call(conn, opts.anubis)

  @spec direct_post(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp direct_post(conn, session_header) do
    with {:ok, body, conn} <- read_body(conn, length: @read_body_length),
         {:ok, message} <- Jason.decode(body) do
      handle_direct_message(conn, session_header, message)
    else
      _error -> send_jsonrpc_error(conn, Error.protocol(:parse_error), nil)
    end
  end

  @spec handle_direct_message(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  defp handle_direct_message(conn, _session_header, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp handle_direct_message(conn, session_header, %{"id" => request_id, "method" => method} = message)
       when method in ["ping", "tools/list", "tools/call"] do
    {:ok, frame} = MCPServer.init(%{}, %Frame{})

    case MCPServer.handle_request(message, frame) do
      {:reply, response, %Frame{}} ->
        send_jsonrpc_response(conn, session_header, request_id, response)

      {:error, %Error{} = error, %Frame{}} ->
        send_jsonrpc_error(conn, error, request_id)
    end
  end

  defp handle_direct_message(conn, _session_header, %{"id" => request_id}) do
    send_jsonrpc_error(conn, Error.protocol(:method_not_found), request_id)
  end

  defp handle_direct_message(conn, _session_header, _message) do
    send_jsonrpc_error(conn, Error.protocol(:invalid_request), nil)
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
