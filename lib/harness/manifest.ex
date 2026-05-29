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
    Harness.ProjectRegistry,
    Harness.Run,
    Harness.ResultStore,
    Harness.AuditReview,
    Harness.AgentAdapter.Driver,
    Harness.Playbooks
  ]

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
  def modules, do: @driver_surface

  api(:mcp_tools, "Render the driver surface as MCP tool definitions.",
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

  @spec mcp_tools(keyword()) :: [map()]
  def mcp_tools(opts \\ []), do: Descripex.MCP.tools(@driver_surface, opts)
end
