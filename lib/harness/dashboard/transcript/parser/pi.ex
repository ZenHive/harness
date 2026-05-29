defmodule Harness.Dashboard.Transcript.Parser.Pi do
  @moduledoc """
  Pi (`pi -p --mode json`) transcript parser.

  Pi's NDJSON stream uses an Anthropic-shaped envelope plus its own session
  bookkeeping events:

    * `{"type": "session", ...}` — banner with cwd, model, provider
    * `{"type": "agent_start"|"turn_start"}` — lifecycle markers
    * `{"type": "message_start"|"message_end", "message": {role, content}}` —
      full message bookends; content is `[{type: "text", text: ...}, …]`
    * `{"type": "message_update", "assistantMessageEvent": {type, ...}}` —
      streaming token deltas; relevant sub-types:
      - `text_start` — first chunk of an assistant response (preamble)
      - `text_delta` — incremental token, payload in `delta`

  The user-visible token sequence comes from `text_delta` events; `text_start`
  folds to `{:system, %{kind: :text_start}}` rather than `:assistant_text`
  (it duplicates the first `text_delta` payload, so it must not double-render).
  All other events fold to `:system`.

  Despite Task 86's body grouping Pi as passthrough, real captures from the
  pi.dev MLX runtime show structured NDJSON — the parser honors the wire.
  """

  alias Harness.Dashboard.Transcript.Parser

  defstruct buffer: ""

  @typedoc "Line-buffer state."
  @type t :: %__MODULE__{buffer: binary()}

  @doc "Returns a fresh parser."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Feeds an iodata `chunk` and returns `{events, parser}`. Non-JSON lines emit `{:unknown, %{raw: line}}`."
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
  defp translate(%{"type" => "session"} = event) do
    [{:system, %{kind: :session, data: event}}]
  end

  defp translate(%{"type" => "agent_start"} = event) do
    [{:system, %{kind: :agent_start, data: event}}]
  end

  defp translate(%{"type" => "turn_start"} = event) do
    [{:system, %{kind: :turn_start, data: event}}]
  end

  defp translate(%{"type" => "message_start"} = event) do
    [{:system, %{kind: :message_start, data: event}}]
  end

  defp translate(%{"type" => "message_end"} = event) do
    [{:system, %{kind: :message_end, data: event}}]
  end

  defp translate(%{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}})
       when is_binary(delta) do
    [{:assistant_text, %{text: delta}}]
  end

  defp translate(%{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_start"}} = event) do
    [{:system, %{kind: :text_start, data: event}}]
  end

  defp translate(%{"type" => "message_update"} = event) do
    [{:system, %{kind: :message_update, data: event}}]
  end

  defp translate(%{"type" => other} = event) when is_binary(other) do
    [{:system, %{kind: :other, data: Map.put(event, "_type", other)}}]
  end

  defp translate(other), do: [{:unknown, %{raw: Jason.encode!(other)}}]
end
