defmodule Harness.Insights.CodexWitness do
  @moduledoc "Codex observer through the owning adapter's explicit read-only contract."
  @behaviour Harness.Insights.Witness

  alias Harness.AgentAdapter.Codex.Observer
  alias Harness.Insights.Prompt
  alias Harness.Insights.ResponseSchema

  @impl true
  @spec observe(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe(evidence, model) do
    case System.find_executable("codex") do
      nil -> {:error, :codex_not_installed}
      executable -> invoke(executable, evidence, model)
    end
  end

  # Exclusive UUID directory; no evidence or provider input controls filesystem paths.
  # sobelow_skip ["Traversal.FileModule"]
  @spec invoke(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp invoke(executable, evidence, model) do
    directory = Path.join(System.tmp_dir!(), "harness-observer-#{Ecto.UUID.generate()}")
    :ok = File.mkdir(directory)
    :ok = File.chmod(directory, 0o700)

    File.write!(Path.join(directory, "response.schema.json"), Jason.encode!(ResponseSchema.schema()), [
      :exclusive
    ])

    path = Path.join(directory, "prompt.txt")
    File.write!(path, Prompt.build(evidence), [:exclusive])

    try do
      with {:ok, {"codex", argv, env}} <- Observer.command(directory, model, "-") do
        case MuonTrap.cmd("/bin/sh", ["-c", ~s(exec "$@" < "$0"), path, executable | argv], timeout: 180_000, env: env) do
          {output, 0} -> decode(output)
          {output, status} -> {:error, {:agent_failed, status, String.slice(output, 0, 8000)}}
        end
      end
    after
      File.rm_rf!(directory)
    end
  end

  @doc "Decodes the CLI's final agent message only after a successful turn completion."
  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  def decode(output) do
    events = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode/1)

    if Enum.any?(events, &match?({:ok, %{"type" => "turn.completed"}}, &1)) and
         not Enum.any?(events, &match?({:ok, %{"type" => "turn.failed"}}, &1)) do
      events
      |> Enum.flat_map(fn
        {:ok, %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}}} -> [text]
        _ -> []
      end)
      |> List.last()
      |> decode_message()
    else
      {:error, {:incomplete_codex_turn, String.slice(output, 0, 8000)}}
    end
  end

  @spec decode_message(term()) :: {:ok, map()} | {:error, atom()}
  defp decode_message(text) when is_binary(text) do
    text = text |> String.trim() |> String.replace_prefix("```json\n", "") |> String.trim_trailing("\n```")

    case Jason.decode(text) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _ -> {:error, {:malformed_agent_output, String.slice(text, 0, 8000)}}
    end
  end

  defp decode_message(_), do: {:error, :missing_agent_message}
end
