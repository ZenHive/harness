defmodule Harness.Dashboard.MCPServer do
  @moduledoc """
  Real MCP server for the harness driver surface (Task 79 rework).

  Built on `anubis_mcp` for protocol compliance (JSON-RPC 2.0, Streamable HTTP
  transport, MCP 2025-11-25 spec). Tools come from `Harness.Manifest` —
  descripex-annotated modules surface as standard MCP tools with JSON Schema
  input descriptions.

  ## Why we override `handle_request/2`

  `anubis_mcp`'s default tool plumbing expects [Peri][peri] schemas, runs them
  through `Peri.validate/2`, and converts to JSON Schema for the wire format.
  Harness already publishes proper JSON Schema via `Descripex.MCP.tools/1`, so
  we bypass anubis's component pipeline for `tools/list` and `tools/call` and
  reuse `Harness.Chat.Tools` (the in-process chat orchestrator's registry +
  dispatcher) — one source of truth for both the chat backend (Task 76) and the
  external MCP surface (Task 79). Everything else (`initialize`, `ping`,
  prompts/resources lists) falls through to anubis's default catch-all clause,
  which is appended by `Anubis.Server`'s `@before_compile` after our two
  `tools/*` clauses (see `deps/anubis_mcp/lib/anubis/server.ex:350-371`).

  [peri]: https://hexdocs.pm/peri
  """

  use Anubis.Server,
    name: "harness",
    version: "0.1.0",
    capabilities: [:tools]

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Harness.Chat.Tools
  alias Harness.JSONSafe

  @impl Anubis.Server
  def init(_client_info, frame) do
    {:ok, Frame.assign(frame, :tool_registry, Tools.build())}
  end

  @impl Anubis.Server
  def handle_request(%{"method" => "tools/list"} = _request, frame) do
    registry = registry(frame)

    tools =
      Enum.map(Tools.schemas(registry), fn schema ->
        %{
          "name" => schema.name,
          "description" => schema.description,
          "inputSchema" => normalize_schema(schema.input_schema)
        }
      end)

    {:reply, %{"tools" => tools}, frame}
  end

  def handle_request(%{"method" => "tools/call", "params" => %{"name" => name} = params}, frame) do
    arguments = Map.get(params, "arguments", %{})
    dispatch_tool(name, arguments, frame)
  end

  # `Tools.dispatch/3`'s success typing currently enumerates the exact error
  # shapes, so dialyzer flags the defensive `{:error, other}` catch-all below
  # as unreachable. Keep the clause — it guards the anubis request handler
  # against a future Tools.dispatch error shape no one updated this case for —
  # and suppress the now-redundant match warning.
  @dialyzer {:no_match, dispatch_tool: 3}
  @spec dispatch_tool(String.t(), map(), Frame.t()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  defp dispatch_tool(name, arguments, frame) do
    case Tools.dispatch(registry(frame), name, arguments) do
      {:ok, result} ->
        {:reply, success_payload(result), frame}

      {:error, {:unknown_tool, _}} ->
        {:error, Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"}), frame}

      {:error, {:schema_validation_failed, errors}} ->
        {:reply, error_payload("Schema validation failed: #{format_errors(errors)}"), frame}

      {:error, {:dispatch_failed, message}} ->
        {:reply, error_payload("Dispatch failed: #{message}"), frame}

      # A novel error shape from Tools.dispatch must not CaseClauseError-crash
      # the anubis request handler; surface it as an MCP tool error instead.
      {:error, other} ->
        {:reply, error_payload("Dispatch failed: #{inspect(other)}"), frame}
    end
  end

  @spec success_payload(term()) :: map()
  defp success_payload(result) do
    text = result |> JSONSafe.encode(JSONSafe.mcp_opts()) |> Jason.encode!()
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}
  end

  @spec error_payload(String.t()) :: map()
  defp error_payload(message) do
    %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
  end

  @spec registry(Frame.t()) :: Tools.registry()
  defp registry(%Frame{assigns: %{tool_registry: registry}}), do: registry

  @spec format_errors([map()]) :: String.t()
  defp format_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: path, message: message} -> "#{path}: #{message}"
      other -> inspect(other)
    end)
  end

  @spec normalize_schema(map()) :: map()
  defp normalize_schema(schema) when is_map(schema) do
    Map.new(schema, fn {k, v} -> {to_string(k), normalize_schema_value(v)} end)
  end

  defp normalize_schema(schema), do: schema

  @spec normalize_schema_value(term()) :: term()
  defp normalize_schema_value(value) when is_map(value), do: normalize_schema(value)
  defp normalize_schema_value(value) when is_list(value), do: Enum.map(value, &normalize_schema_value/1)
  defp normalize_schema_value(value), do: value
end
