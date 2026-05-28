defmodule Harness.Dashboard.MCP do
  @moduledoc """
  Headless JSON surface for Descripex-backed harness tools.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  @default_enabled Mix.env() in [:dev, :test]

  @type violation :: %{path: String.t(), message: String.t()}

  @doc "Returns whether the headless MCP dashboard surface is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:harness, :mcp_enabled, @default_enabled)
  end

  @doc "Serves the MCP tool list generated from `Harness.Manifest`."
  @spec tools(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def tools(conn, _params) do
    if enabled?() do
      send_json(conn, 200, %{tools: Harness.Manifest.mcp_tools()})
    else
      send_json(conn, 404, %{error: "not_found"})
    end
  end

  @doc "Validates and dispatches one MCP tool call."
  @spec invoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def invoke(conn, _params) do
    if enabled?() do
      dispatch_call(conn)
    else
      send_json(conn, 404, %{error: "not_found"})
    end
  end

  @spec dispatch_call(Plug.Conn.t()) :: Plug.Conn.t()
  defp dispatch_call(%Plug.Conn{body_params: %{"name" => name, "arguments" => arguments}} = conn)
       when is_binary(name) and is_map(arguments) do
    case find_tool(name) do
      nil ->
        send_json(conn, 404, %{error: "unknown_tool", name: name})

      tool ->
        case validate_arguments(tool.input_schema, arguments) do
          :ok ->
            result =
              tool.module
              |> apply(tool.function, build_args(tool, arguments))
              |> json_safe()

            send_json(conn, 200, %{result: result})

          {:error, violations} ->
            send_json(conn, 422, %{error: "schema_validation_failed", violations: violations})
        end
    end
  end

  defp dispatch_call(conn) do
    send_json(conn, 400, %{error: "invalid_request", message: "expected JSON object with name and arguments"})
  end

  @spec find_tool(String.t()) :: map() | nil
  defp find_tool(name) do
    Enum.find(tool_index(), &(&1.name == name))
  end

  @spec tool_index() :: [map()]
  defp tool_index do
    tool_schemas = Map.new(Harness.Manifest.mcp_tools(), &{&1.name, &1.inputSchema})

    Enum.flat_map(Harness.Manifest.modules(), fn module ->
      prefix = module_prefix(module)

      Enum.map(module.__api__(), fn entry ->
        name = "#{prefix}__#{entry.name}"

        %{
          name: name,
          module: module,
          function: entry.name,
          arity: entry.arity,
          input_schema: Map.fetch!(tool_schemas, name),
          param_names: param_names(module, entry.name, entry.arity)
        }
      end)
    end)
  end

  @spec validate_arguments(map(), map()) :: :ok | {:error, [violation()]}
  defp validate_arguments(schema, arguments) do
    violations =
      schema
      |> Map.get(:required, Map.get(schema, "required", []))
      |> Enum.flat_map(&required_violation(&1, arguments))

    case violations do
      [] -> :ok
      _ -> {:error, violations}
    end
  end

  @spec required_violation(String.t(), map()) :: [violation()]
  defp required_violation(name, arguments) do
    if Map.has_key?(arguments, name) do
      []
    else
      [%{path: "/#{name}", message: "required property is missing"}]
    end
  end

  @spec build_args(map(), map()) :: [term()]
  defp build_args(%{param_names: param_names, input_schema: schema}, arguments) do
    required = Map.get(schema, :required, Map.get(schema, "required", []))

    param_names
    |> Enum.take_while(fn name -> Map.has_key?(arguments, name) or name in required end)
    |> Enum.map(&Map.fetch!(arguments, &1))
  end

  @spec param_names(module(), atom(), non_neg_integer()) :: [String.t()]
  defp param_names(module, name, arity) do
    with {:docs_v1, _, _, _, _, _, docs} <- Code.fetch_docs(module),
         {{:function, ^name, ^arity}, _, [signature | _], _, _} <-
           Enum.find(docs, &function_doc?(&1, name, arity)) do
      signature
      |> String.replace(~r/^[^(]+\(|\)$/u, "")
      |> String.split(",", trim: true)
      |> Enum.map(&param_name/1)
    else
      _ -> []
    end
  end

  @spec function_doc?(tuple(), atom(), non_neg_integer()) :: boolean()
  defp function_doc?({{:function, name, arity}, _, _, _, _}, name, arity), do: true
  defp function_doc?(_doc, _name, _arity), do: false

  @spec param_name(String.t()) :: String.t()
  defp param_name(param) do
    param
    |> String.split("\\\\", parts: 2)
    |> hd()
    |> String.trim()
  end

  @spec module_prefix(module()) :: String.t()
  defp module_prefix(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @spec send_json(Plug.Conn.t(), Plug.Conn.status(), term()) :: Plug.Conn.t()
  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  @spec json_safe(term()) :: term()
  defp json_safe(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(%{} = value) do
    Map.new(value, fn {key, val} -> {json_key(key), json_safe(val)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
    do: inspect(value)

  defp json_safe(value), do: value

  @spec json_key(term()) :: String.t()
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)
end
