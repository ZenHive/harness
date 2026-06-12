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
    Harness.Run.Supervisor,
    Harness.Batch,
    Harness.Batch.AgentEvaluation,
    Harness.Roadmap,
    Harness.Dispatch,
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
  # supervisor-start_run, the batch-* / agent_evaluation-* tools) is excluded
  # from the MCP/chat surface. They stay on the full Elixir driver surface
  # (build/0, modules/0) for in-process callers. The flat dispatch-task tool is
  # the JSON-native replacement for the struct-passing ingest → start_run flow.
  @spec mcp_tools(keyword()) :: [map()]
  def mcp_tools(opts \\ []) do
    @driver_surface
    |> Descripex.MCP.tools(opts)
    |> Enum.map(&transform_tool_name/1)
    |> Enum.reject(&struct_arg_tool?/1)
  end

  defp transform_tool_name(%{name: name} = tool) do
    %{tool | name: String.replace(name, "__", @tool_name_delimiter)}
  end

  @spec struct_arg_tool?(map()) :: boolean()
  defp struct_arg_tool?(%{name: name}) do
    delim = @tool_name_delimiter

    with [prefix, func] <- String.split(name, delim, parts: 2),
         {:ok, module} <- Map.fetch(@prefix_to_module, prefix) do
      exchange_data_params?(module, func)
    else
      _ -> false
    end
  end

  # `func` is the name of an api()-annotated function on a curated driver module,
  # so the atom already exists — not user-supplied free text.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec exchange_data_params?(module(), String.t()) :: boolean()
  defp exchange_data_params?(module, func) do
    case module.__api__(String.to_existing_atom(func)) do
      nil -> false
      entry -> Enum.any?(entry.hints[:params] || %{}, fn {_key, details} -> details[:kind] == :exchange_data end)
    end
  end
end
