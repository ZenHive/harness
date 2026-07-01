defmodule Harness.Manifest do
  @moduledoc """
  Single entry point exposing the harness driver surface as a machine-readable manifest.

  Wraps `Descripex.Manifest.build/1` over the curated list of modules that make
  up the AI orchestrator dispatch contract — `Harness.Run.Supervisor`,
  `Harness.Batch`, `Harness.Batch.AgentEvaluation`, `Harness.Roadmap`,
  `Harness.ProjectRegistry`, `Harness.Run`, `Harness.ResultStore`,
  `Harness.AuditReview`, `Harness.AgentAdapter.Driver`, and `Harness.Playbooks`.

  The same manifest powers the in-process chat orchestrator's tool dispatch
  (Task 76) and the external MCP endpoint (Task 79); both surfaces resolve the
  curated list through this module so the contract stays consistent.

  Use `modules/0` when you want the module list directly (for example, to call
  `Descripex.MCP.tools/1` or `Descripex.Describe.describe/1-3`).
  """

  use Descripex, namespace: "/manifest"

  @driver_surface [
    Harness.Agents,
    Harness.Routing,
    Harness.Autonomy,
    Harness.Run.Supervisor,
    Harness.Batch,
    Harness.Batch.AgentEvaluation,
    Harness.Roadmap,
    Harness.Dispatch,
    Harness.CodeSearch,
    Harness.Config,
    Harness.Describe,
    Harness.ModelAvailability,
    Harness.ProjectRegistry,
    Harness.Run,
    Harness.ResultStore,
    Harness.AuditReview,
    Harness.AgentAdapter.Driver,
    Harness.Playbooks
  ]

  # Tool-name prefix (a module's last segment, snake_cased — the shape
  # Descripex.MCP.tools/2 derives) → source module. Used to map a generated MCP
  # tool name back to its module so mcp_tools/1 can inspect the function's
  # param kinds.
  @prefix_to_module Map.new(@driver_surface, fn module ->
                      {module |> Module.split() |> List.last() |> Macro.underscore(), module}
                    end)

  # Single delimiter between the logical group (module short name) and action
  # (function) in generated MCP/chat tool names. Descripex hardcodes "__" as
  # joiner in MCP.tools/2; we transform to this delimiter so that client
  # namespacing (`<server>__<tool>`) never produces a qualified name containing
  # "__" more than once. Chosen char is in MCP tool-name charset [a-zA-Z0-9_-].
  # This is the convention source: both MCP server and in-process Chat.Tools
  # read the emitted names (and split for reverse lookup) from here.
  @tool_name_delimiter "-"

  @doc "The single group/action delimiter used in generated MCP/chat tool names (not `\"__\"`)."
  @spec tool_name_delimiter() :: String.t()
  def tool_name_delimiter, do: @tool_name_delimiter

  api(:build, "Build the harness driver-surface manifest (JSON-serializable).",
    returns: %{
      type: :map,
      description:
        "%{version: \"1.0\", generated_at: ISO8601, modules: [...]} — descripex manifest covering the curated driver surface. Suitable for serving to MCP clients or feeding the chat orchestrator's tool dispatch."
    }
  )

  @spec build() :: map()
  def build, do: Descripex.Manifest.build(@driver_surface)

  api(:modules, "Return the curated driver-surface module list.",
    returns: %{
      type: :list,
      description:
        "Modules annotated with descripex api() declarations. Stable contract — downstream code uses this list directly."
    }
  )

  @spec modules() :: [module()]
  def modules do
    Enum.each(@driver_surface, &Code.ensure_loaded!/1)
    @driver_surface
  end

  api(:mcp_tools, "Render the JSON-driveable driver surface as MCP tool definitions.",
    params: [
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword list forwarded to Descripex.MCP.tools/2. :name_style (:short | :full) controls tool name shape (default :short — module last segment, snake_case)."
      ]
    ],
    returns: %{
      type: :list,
      description: "List of %{name, description, inputSchema} MCP tool maps suitable for the external MCP endpoint."
    }
  )

  # Only tools driveable over a stateless JSON boundary are returned: any tool
  # with an :exchange_data param (a struct a JSON caller cannot construct — e.g.
  # supervisor-start_run, the batch-* / agent_evaluation-* tools) or a
  # `kind: :value` param whose description documents a struct / module() /
  # module-list shape JSON cannot supply (e.g. agent_evaluation-from_batch,
  # result_store-record_run) is excluded from the MCP/chat surface. They stay on
  # the full Elixir driver surface (build/0, modules/0) for in-process callers.
  # The flat dispatch-task tool is the JSON-native replacement for the
  # struct-passing ingest → start_run flow.
  @spec mcp_tools(keyword()) :: [map()]
  def mcp_tools(opts \\ []) do
    @driver_surface
    |> Descripex.MCP.tools(opts)
    |> Enum.map(&transform_tool_name/1)
    |> Enum.reject(&struct_arg_tool?/1)
  end

  @doc false
  @spec resolve_tool!(map(), [module()]) :: map()
  def resolve_tool!(%{name: name, description: description, inputSchema: schema}, modules) do
    delim = @tool_name_delimiter

    {prefix, func_name} =
      case String.split(name, delim, parts: 2) do
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
      param_keys: api_entry.param_order,
      params: params,
      returns: api_entry.hints[:returns]
    }
  end

  @doc "Describe one JSON-driveable MCP tool by name."
  @spec describe_tool(String.t()) :: {:ok, map()} | {:error, {:unknown_tool, String.t()}}
  def describe_tool(name) when is_binary(name) do
    modules = modules()

    case Enum.find(mcp_tools(), &(&1.name == name)) do
      nil -> {:error, {:unknown_tool, name}}
      tool -> {:ok, describe_resolved_tool(resolve_tool!(tool, modules))}
    end
  end

  defp transform_tool_name(%{name: name} = tool) do
    %{tool | name: String.replace(name, "__", @tool_name_delimiter)}
  end

  @spec describe_resolved_tool(map()) :: map()
  defp describe_resolved_tool(entry) do
    required = MapSet.new(entry.input_schema.required || [])

    %{
      name: entry.name,
      description: entry.description,
      params: Enum.map(entry.param_keys, &describe_param(&1, entry.params, required)),
      returns: entry.returns
    }
  end

  @spec describe_param(atom(), map(), MapSet.t(String.t())) :: map()
  defp describe_param(key, params, required) do
    details = Map.get(params, key, %{})
    str_key = Atom.to_string(key)

    %{
      name: str_key,
      kind: details[:kind],
      required: MapSet.member?(required, str_key),
      default: Map.get(details, :default),
      description: Map.get(details, :description)
    }
  end

  @spec struct_arg_tool?(map()) :: boolean()
  defp struct_arg_tool?(%{name: name}) do
    delim = @tool_name_delimiter

    with [prefix, func] <- String.split(name, delim, parts: 2),
         {:ok, module} <- Map.fetch(@prefix_to_module, prefix),
         entry when not is_nil(entry) <- module.__api__(String.to_existing_atom(func)) do
      exchange_data_params?(entry) or unjsonifiable_params?(entry)
    else
      _ -> false
    end
  end

  @spec exchange_data_params?(map()) :: boolean()
  defp exchange_data_params?(%{hints: %{params: params}}) when is_map(params) do
    Enum.any?(params, fn {_key, details} -> details[:kind] == :exchange_data end)
  end

  defp exchange_data_params?(_entry), do: false

  @spec unjsonifiable_params?(map()) :: boolean()
  defp unjsonifiable_params?(%{hints: %{params: params}}) when is_map(params) do
    Enum.any?(params, &unjsonifiable_param?/1)
  end

  defp unjsonifiable_params?(_entry), do: false

  # Mechanical filter: if the api() description documents a struct, module(), or
  # module list, a JSON MCP client cannot construct the param — drop the tool.
  @spec unjsonifiable_param?(map()) :: boolean()
  defp unjsonifiable_param?({:opts, _details}), do: false

  defp unjsonifiable_param?({_name, details}) when is_map(details) do
    desc = Map.get(details, :description, "")

    primary_struct_description?(desc) or primary_module_type_description?(desc) or
      adapter_module_list?(desc)
  end

  defp unjsonifiable_param?(_), do: false

  # Only the param's own shape — not structs named inside an opts keyword list.
  @spec primary_struct_description?(String.t()) :: boolean()
  defp primary_struct_description?(desc) do
    Regex.match?(~r/^%[A-Za-z0-9_.]+\{/, desc) or
      Regex.match?(~r/\b[A-Za-z0-9_.]+ struct\b/i, desc)
  end

  @spec primary_module_type_description?(String.t()) :: boolean()
  defp primary_module_type_description?(desc) do
    Regex.match?(~r/^[^.]*\bmodule\(\)/, desc)
  end

  @spec adapter_module_list?(String.t()) :: boolean()
  defp adapter_module_list?(desc), do: Regex.match?(~r/\blist of adapter modules\b/i, desc)

  @spec resolve_module!([module()], String.t()) :: module()
  defp resolve_module!(modules, prefix) do
    case Enum.filter(modules, fn mod ->
           mod
           |> Module.split()
           |> List.last()
           |> Macro.underscore() == prefix
         end) do
      [module] ->
        module

      [] ->
        raise ArgumentError, "no module for tool prefix #{inspect(prefix)}"

      multiple ->
        raise ArgumentError, "ambiguous tool prefix #{inspect(prefix)}: #{inspect(multiple)}"
    end
  end
end
