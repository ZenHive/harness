defmodule Harness.Chat.Tools do
  @moduledoc """
  Tool registry and dispatch for chat sessions.

  Built from `Harness.Manifest` at session startup — each MCP tool name maps to
  an MFA plus its JSON Schema. Dispatch validates arguments before `apply/3`.
  """

  alias Harness.Chat.Schema

  @typedoc "Resolved tool entry keyed by MCP tool name."
  @type entry :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:module) => module(),
          required(:function) => atom(),
          required(:arity) => non_neg_integer(),
          required(:defaults) => non_neg_integer(),
          required(:input_schema) => map(),
          required(:param_keys) => [atom()],
          required(:params) => map()
        }

  @type registry :: %{String.t() => entry()}

  @doc "Builds a tool registry from the curated driver surface."
  @spec build(keyword()) :: registry()
  def build(opts \\ []) do
    modules = Keyword.get(opts, :modules, Harness.Manifest.modules())

    opts
    |> Keyword.take([:name_style])
    |> Harness.Manifest.mcp_tools()
    |> Map.new(fn tool ->
      entry = resolve_tool!(tool, modules)
      {tool.name, entry}
    end)
  end

  @doc "Returns MCP tool definitions suitable for backend requests."
  @spec schemas(registry()) :: [map()]
  def schemas(registry) when is_map(registry) do
    Enum.map(registry, fn {_name, entry} ->
      %{
        name: entry.name,
        description: entry.description,
        input_schema: entry.input_schema
      }
    end)
  end

  @doc "Dispatches `tool_name` with JSON `arguments` via apply/3 after schema validation."
  @spec dispatch(registry(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(registry, tool_name, arguments) when is_map(registry) and is_binary(tool_name) and is_map(arguments) do
    with {:ok, entry} <- lookup(registry, tool_name),
         :ok <- validate_args(entry, arguments),
         {:ok, args} <- build_apply_args(entry, arguments) do
      safe_apply(entry, args)
    end
  end

  @spec lookup(registry(), String.t()) :: {:ok, entry()} | {:error, {:unknown_tool, String.t()}}
  defp lookup(registry, tool_name) do
    case Map.fetch(registry, tool_name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_tool, tool_name}}
    end
  end

  # Wrap `Schema.validate/2`'s generic `{:error, [violations]}` into the
  # `{:schema_validation_failed, ...}` shape every downstream surface (chat
  # backend + MCP server) pattern-matches.
  @spec validate_args(entry(), map()) ::
          :ok | {:error, {:schema_validation_failed, [Schema.error()]}}
  defp validate_args(entry, arguments) do
    case Schema.validate(arguments, entry.input_schema) do
      :ok -> :ok
      {:error, violations} -> {:error, {:schema_validation_failed, violations}}
    end
  end

  @spec resolve_tool!(map(), [module()]) :: entry()
  defp resolve_tool!(%{name: name, description: description, inputSchema: schema}, modules) do
    {prefix, func_name} =
      case String.split(name, "__", parts: 2) do
        [prefix, func_name] -> {prefix, func_name}
        _ -> raise ArgumentError, "invalid MCP tool name #{inspect(name)}"
      end

    module = resolve_module!(modules, prefix)
    function = String.to_existing_atom(func_name)
    api_entry = module.__api__(function) || raise ArgumentError, "missing __api__ for #{name}"
    params = api_entry.hints[:params] || %{}

    %{
      name: name,
      description: description,
      module: module,
      function: function,
      arity: api_entry.arity,
      defaults: api_entry.defaults,
      input_schema: schema,
      param_keys: Map.keys(params),
      params: params
    }
  end

  # Prefix comes from MCP tool names derived from the curated Manifest module list —
  # not user-supplied free text.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec resolve_module!([module()], String.t()) :: module()
  defp resolve_module!(modules, prefix) do
    short = String.to_atom(prefix)

    case Enum.filter(modules, fn mod ->
           mod
           |> Module.split()
           |> List.last()
           |> Macro.underscore()
           |> String.to_atom() == short
         end) do
      [module] ->
        module

      [] ->
        raise ArgumentError, "no module for tool prefix #{inspect(prefix)}"

      multiple ->
        raise ArgumentError, "ambiguous tool prefix #{inspect(prefix)}: #{inspect(multiple)}"
    end
  end

  @spec build_apply_args(entry(), map()) :: {:ok, [term()]} | {:error, {:schema_validation_failed, [map()]}}
  defp build_apply_args(entry, arguments) do
    args = Enum.map(entry.param_keys, &resolve_param(entry, &1, arguments))

    if Enum.any?(args, &(&1 == :__missing__)) do
      {:error, {:schema_validation_failed, [%{path: "#", message: "missing required arguments for #{entry.name}"}]}}
    else
      {:ok, args}
    end
  end

  @spec resolve_param(entry(), atom(), map()) :: term()
  defp resolve_param(%{params: params}, key, arguments) do
    key_str = Atom.to_string(key)

    case Map.get(arguments, key_str, Map.get(arguments, key)) do
      nil ->
        case Map.get(params, key, %{}) do
          %{default: default} -> default
          _ -> :__missing__
        end

      value ->
        decode_param(value, Map.get(params, key, %{}))
    end
  end

  @spec decode_param(term(), map()) :: term()
  defp decode_param(value, %{kind: :value}) when is_binary(value) do
    if String.starts_with?(value, ":") do
      value |> String.slice(1..-1//1) |> String.to_existing_atom()
    else
      value
    end
  rescue
    ArgumentError -> value
  end

  defp decode_param(value, %{kind: :value}) when is_map(value), do: atomize_keys(value)
  defp decode_param(value, _details), do: value

  @spec safe_apply(entry(), [term()]) :: {:ok, term()} | {:error, term()}
  defp safe_apply(%{module: module, function: function}, args) do
    {:ok, apply(module, function, args)}
  rescue
    error -> {:error, {:dispatch_failed, Exception.message(error)}}
  end

  @spec atomize_keys(map()) :: map()
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      atom_key =
        key
        |> to_string()
        |> String.to_existing_atom()

      {atom_key, atomize_value(value)}
    end)
  rescue
    ArgumentError ->
      map
  end

  @spec atomize_value(term()) :: term()
  defp atomize_value(value) when is_map(value), do: atomize_keys(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value
end
