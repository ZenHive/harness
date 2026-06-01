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

  alias Harness.Dashboard.Transcript.Parser

  defstruct buffer: ""

  @typedoc "Line-buffer state."
  @type t :: %__MODULE__{buffer: binary()}

  @doc "Returns a fresh parser."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds an iodata `chunk` and returns `{events, parser}`. Non-JSON lines
  (ANSI-coloured stderr noise on auth / transport errors) emit
  `{:unknown, %{raw: line}}`.
  """
  @spec feed(t(), iodata()) :: {[Parser.event()], t()}
  def feed(%__MODULE__{} = parser, chunk) do
    combined = parser.buffer <> IO.iodata_to_binary(chunk)
    {complete, remainder} = split_lines(combined)
    events = Enum.flat_map(complete, &parse_line/1)
    {events, %{parser | buffer: remainder}}
  end

  @doc "Flushes the buffer at port close — same semantics as `feed/2`."
  @spec finalize(t()) :: {[Parser.event()], t()}
  def finalize(%__MODULE__{buffer: ""} = parser), do: {[], parser}

  def finalize(%__MODULE__{buffer: leftover} = parser) do
    {parse_line(leftover), %{parser | buffer: ""}}
  end

  @spec split_lines(binary()) :: {[binary()], binary()}
  defp split_lines(string) do
    case String.split(string, "\n") do
      [single] -> {[], single}
      many -> {Enum.drop(many, -1), List.last(many)}
    end
  end

  @spec parse_line(binary()) :: [Parser.event()]
  defp parse_line(""), do: []

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> translate(decoded)
      {:error, _} -> [{:unknown, %{raw: line}}]
    end
  end

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
