defmodule Harness.Dashboard.Transcript.Parser.Cursor do
  @moduledoc """
  Cursor (`cursor-agent -p --output-format stream-json`) transcript parser.

  Cursor's NDJSON stream is structurally near-identical to Claude Code's —
  one JSON object per line, `system/init` + `assistant` (text and tool_use
  blocks) + `user` (tool_result blocks) + `result`. The line-buffering and
  block-translation logic is the same; this module exists as a separate
  dispatch target so Cursor-specific divergences (different field names in
  `system/init`, different metadata on tool calls) can be handled here
  without coupling to the Claude parser.

  Today the translate clauses are a direct mirror of Claude's. As cursor's
  wire format evolves and diverges, this module is the place to capture
  cursor-only behavior.
  """

  alias Harness.Dashboard.Transcript.Parser

  defstruct buffer: ""

  @typedoc "Line-buffer carrying any partial trailing bytes between chunks."
  @type t :: %__MODULE__{buffer: binary()}

  @doc "Returns a fresh parser with an empty line buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds an iodata `chunk` and returns `{events, parser}`. Non-JSON lines
  emit `{:unknown, %{raw: line}}` and are not silently dropped.
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
  defp translate(%{"type" => "system", "subtype" => "init"} = event) do
    [{:system, %{kind: :init, data: event}}]
  end

  defp translate(%{"type" => "system"} = event) do
    [{:system, %{kind: system_kind(event), data: event}}]
  end

  defp translate(%{"type" => "assistant", "message" => %{"content" => blocks}}) when is_list(blocks) do
    Enum.flat_map(blocks, &translate_assistant_block/1)
  end

  defp translate(%{"type" => "user", "message" => %{"content" => blocks}}) when is_list(blocks) do
    Enum.flat_map(blocks, &translate_user_block/1)
  end

  defp translate(%{"type" => "result"} = result) do
    [{:system, %{kind: :result, data: result}}]
  end

  defp translate(%{"type" => other} = event) when is_binary(other) do
    [{:system, %{kind: :other, data: Map.put(event, "_type", other)}}]
  end

  defp translate(other), do: [{:unknown, %{raw: Jason.encode!(other)}}]

  # Bounded atom set — cursor's subtype vocabulary mirrors claude's loosely
  # and shifts across releases; unknown subtypes fold to :other.
  @spec system_kind(map()) :: atom()
  defp system_kind(%{"subtype" => "init"}), do: :init
  defp system_kind(%{"subtype" => sub}) when is_binary(sub), do: :other
  defp system_kind(_), do: :system

  @spec translate_assistant_block(map()) :: [Parser.event()]
  defp translate_assistant_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    [{:assistant_text, %{text: text}}]
  end

  defp translate_assistant_block(%{"type" => "tool_use"} = block) do
    [
      {:assistant_tool_use,
       %{
         id: Map.get(block, "id", ""),
         name: Map.get(block, "name", ""),
         input: Map.get(block, "input", %{})
       }}
    ]
  end

  defp translate_assistant_block(_), do: []

  @spec translate_user_block(map()) :: [Parser.event()]
  defp translate_user_block(%{"type" => "tool_result"} = block) do
    [
      {:tool_result,
       %{
         tool_use_id: Map.get(block, "tool_use_id", ""),
         content: Map.get(block, "content")
       }}
    ]
  end

  defp translate_user_block(_), do: []
end
