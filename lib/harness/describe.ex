defmodule Harness.Describe do
  @moduledoc """
  Self-description tools for clients that cannot call protocol-level tools/list.

  The catalog is the same curated MCP surface exposed by `Harness.Manifest`; the
  detailed schema path delegates to `Harness.Manifest.describe_tool/1`.
  """

  use Descripex, namespace: "/describe"

  alias Harness.Manifest

  @typedoc "One tool catalog row."
  @type tool_summary :: %{name: String.t(), description: String.t()}

  api(:tools, "List the harness MCP tool catalog with names and descriptions.",
    returns: %{
      type: :list,
      description: "[%{name, description}] for every JSON-driveable harness MCP tool."
    }
  )

  @spec tools() :: [tool_summary()]
  def tools do
    Enum.map(Manifest.mcp_tools(), &%{name: &1.name, description: &1.description})
  end

  api(:tool, "Describe one harness MCP tool by name, including params and return metadata.",
    params: [
      name: [kind: :value, description: "Tool name from describe-tools, e.g. \"agents-list\".", schema: String.t()]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{name, description, params: [%{name, kind, required, default, description}], returns}} or {:error, {:unknown_tool, name}}."
    }
  )

  @spec tool(String.t()) :: {:ok, map()} | {:error, {:unknown_tool, String.t()}}
  def tool(name) when is_binary(name), do: Manifest.describe_tool(name)
end
