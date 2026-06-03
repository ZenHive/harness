defmodule Harness.Dashboard.Transcript.Parser.Grok do
  @moduledoc """
  Grok (`grok -p --output-format streaming-json`) transcript parser.

  Grok streams token-by-token deltas with a small event vocabulary:

    * `{"type": "thought", "data": <token-fragment>}` — chain-of-thought
      tokens (reasoning, not final answer). Surfaced as
      `{:system, %{kind: :thought, data: %{text: fragment}}}` so Task 87's
      renderer can separate reasoning from final assistant text.
    * `{"type": "text", "data": <token-fragment>}` — final-answer tokens →
      `{:assistant_text, %{text: fragment}}`.
    * `{"type": "end", ...}` — turn termination with `stopReason` →
      `{:system, %{kind: :end, data: event}}`.

  Grok also emits ANSI-coloured stderr noise on auth / transport errors;
  `:stderr_to_stdout` folds those into the captured stream. Those non-JSON
  lines emit `{:unknown, %{raw: line}}` and are preserved per Task 86's
  "no silent drops" criterion.

  Despite Task 86's body grouping Grok as passthrough, real captures show
  structured NDJSON token deltas — the parser honors what the wire emits.

  ## Tool-call / tool-result limitation (Task 136)

  Grok's `streaming-json` NDJSON for `-p` headless only ever emits `thought`,
  `text`, and `end` (plus ANSI stderr noise). Real action-producing runs
  (multi-file diffs) and the CLI docs confirm no `tool_use`/`tool_result`/
  command events appear on the wire. This parser therefore never emits
  `:assistant_tool_use` or `:tool_result`; the transcript view shows only
  reasoning + assistant text for grok. Non-JSON lines surface as `:unknown`;
  other JSON types surface as `:system, kind: :other`. Consult raw pane +
  diff_size for action evidence. Wire-format limitation, not parser gap.
  """

  use Harness.Dashboard.Transcript.Parser

  @spec translate(map()) :: [Parser.event()]
  defp translate(%{"type" => "text", "data" => fragment}) when is_binary(fragment) do
    [{:assistant_text, %{text: fragment}}]
  end

  defp translate(%{"type" => "thought", "data" => fragment}) when is_binary(fragment) do
    [{:system, %{kind: :thought, data: %{text: fragment}}}]
  end

  defp translate(%{"type" => "end"} = event) do
    [{:system, %{kind: :end, data: event}}]
  end

  defp translate(%{"type" => other} = event) when is_binary(other) do
    [{:system, %{kind: :other, data: Map.put(event, "_type", other)}}]
  end

  defp translate(other), do: [{:unknown, %{raw: Jason.encode!(other)}}]
end
