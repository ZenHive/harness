defmodule Harness.Insights.Witness do
  @moduledoc "Tool-free AI boundary for advisory run observations."
  alias Harness.Insights.Prompt

  @doc "Returns advisory finding data or a provider failure from bounded evidence."
  @callback observe(map(), String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Invokes Claude with all tools, MCP, hooks, skills and customizations disabled."
  @spec observe(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe(evidence, model) do
    case System.find_executable("claude") do
      nil -> {:error, :claude_not_installed}
      executable -> invoke(executable, evidence, model)
    end
  end

  @doc false
  @spec arguments(String.t(), String.t()) :: [String.t()]
  def arguments(model, prompt) do
    [
      "--print",
      "--safe-mode",
      "--tools",
      "",
      "--strict-mcp-config",
      "--mcp-config",
      "{\"mcpServers\":{}}",
      "--disable-slash-commands",
      "--no-session-persistence",
      "--setting-sources",
      "",
      "--settings",
      "{\"disableAllHooks\":true}",
      "--output-format",
      "json",
      "--model",
      model,
      "--",
      prompt
    ]
  end

  # The path is generated here from the OS temp directory and a fresh UUID; no input controls it.
  # Exclusive creation prevents following an existing symlink.
  # sobelow_skip ["Traversal.FileModule"]
  @spec invoke(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp invoke(executable, evidence, model) do
    prompt = Prompt.build(evidence)

    path = Path.join(System.tmp_dir!(), "harness-insights-#{Ecto.UUID.generate()}.txt")
    File.write!(path, prompt, [:exclusive])
    File.chmod!(path, 0o600)

    try do
      args = model |> arguments("") |> Enum.drop(-2)

      case MuonTrap.cmd("/bin/sh", ["-c", ~s(exec "$@" < "$0"), path, executable | args], timeout: 180_000) do
        {output, 0} -> decode(output)
        {output, status} -> {:error, {:agent_failed, status, String.slice(output, 0, 2000)}}
      end
    after
      File.rm(path)
    end
  end

  @spec json_text(String.t()) :: String.t()
  defp json_text("```json\n" <> fenced), do: String.trim_trailing(fenced, "\n```")
  defp json_text(text), do: text

  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  defp decode(output) do
    with {:ok, %{"is_error" => false, "result" => result}} <- Jason.decode(output),
         {:ok, response} when is_map(response) <- Jason.decode(json_text(result)) do
      {:ok, response}
    else
      _ -> {:error, {:malformed_agent_output, String.slice(output, 0, 8000)}}
    end
  end
end
