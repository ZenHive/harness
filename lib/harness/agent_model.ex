defmodule Harness.AgentModel do
  @moduledoc """
  The LLM model an agent reported using, parsed from its raw transcript.

  A companion to `Harness.TokenUsage`: where that extracts token counts, this
  extracts the model identifier the agent self-reports, so the dashboard can
  show *which model did this run* rather than only *which agent*. Like token
  usage it is best-effort and adapter-specific — a transcript that names no
  model parses to `nil`, never a crash.

  ## Per-adapter strategy

    * `:claude` — Anthropic `stream-json` carries the model id (e.g.
      `claude-opus-4-8`) as a top-level `model` on its `system`/`assistant`/
      `result` events.
    * `:cursor` — the `system`/`init` event carries a top-level `model`
      (e.g. `Composer 2.5 Fast`).
    * `:codex` / `:grok` / `:antigravity` / `:pi` / unknown — their `--json` /
      streaming output carries no model field (verified against captured
      transcripts), so they parse to `nil`. The *requested* model (from the
      rmap task) is a separate fact not present in the agent's output.
  """

  @typedoc "Adapter atom keys mirror `Harness.TokenUsage.agent_kind/0`."
  @type agent_kind :: Harness.TokenUsage.agent_kind()

  @doc """
  Parses the reported model id from `output` for `kind`, or `nil`.

  Tolerant by construction: a non-binary `output`, malformed lines, or a
  transcript with no model field all yield `nil` rather than raising.
  """
  @spec parse(agent_kind(), term()) :: String.t() | nil
  def parse(_kind, output) when not is_binary(output), do: nil
  def parse(:claude, output), do: first_model(output)
  def parse(:cursor, output), do: first_model(output)
  def parse(_other, _output), do: nil

  # The first model id found scanning events in arrival order — agents restate
  # the model on every event, so the earliest is as good as any and avoids
  # walking the whole transcript once found.
  @spec first_model(binary()) :: String.t() | nil
  defp first_model(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(&model_from_line/1)
  end

  @spec model_from_line(binary()) :: String.t() | nil
  defp model_from_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, object} when is_map(object) -> model_from_object(object)
      _ -> nil
    end
  end

  # The model id surfaces at the top level (`model`) for claude/cursor, with a
  # nested `message.model` / `data.model` accepted defensively for wire-format
  # drift. Only a non-empty string counts.
  @spec model_from_object(map()) :: String.t() | nil
  defp model_from_object(object) do
    Enum.find([object["model"], dig(object, ["message", "model"]), dig(object, ["data", "model"])], &valid_model?/1)
  end

  @spec dig(term(), [String.t()]) :: term()
  defp dig(value, keys) do
    Enum.reduce(keys, value, fn key, acc -> if is_map(acc), do: Map.get(acc, key) end)
  end

  @spec valid_model?(term()) :: boolean()
  defp valid_model?(value), do: is_binary(value) and value != ""
end
