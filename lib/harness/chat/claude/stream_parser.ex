defmodule Harness.Chat.Claude.StreamParser do
  @moduledoc """
  Line-buffered stream-json parser for Claude Code's `--output-format
  stream-json --verbose` headless output (Task 82).

  Each line in Claude Code's stream is a complete JSON event:

    * `system` / `subtype: "init"` — session metadata at start of turn
    * `assistant` — assistant message with one or more content blocks
      (`text`, `tool_use`)
    * `user` — tool-result follow-ups emitted by Claude's internal tool loop
    * `result` — terminal event with `stop_reason`, `session_id`, etc.

  Port chunks may split mid-line, so the parser keeps an internal buffer and
  only emits events for fully-terminated lines. `finalize/1` flushes any
  trailing line that became complete at port close.

  Pure module — no Port, no IO, no side effects. Tested directly with byte
  fragments.
  """

  alias Harness.LineBuffer

  defstruct buffer: ""

  @typedoc "Stream-parser state — accumulates partial-line bytes between Port chunks."
  @type t :: %__MODULE__{buffer: binary()}

  @typedoc "Normalized event surfaced upward; consumers decide which to fan out."
  @type event ::
          {:assistant_text, String.t()}
          | {:assistant_tool_use, %{id: String.t(), name: String.t(), input: map()}}
          | {:tool_result, %{tool_use_id: String.t(), content: term()}}
          | {:system_init, map()}
          | {:result, map()}
          | {:unknown, map()}

  @doc "Returns a fresh parser with an empty line buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds an iodata `chunk` into the parser. Returns `{events, parser}` where
  `events` are emitted in arrival order. Non-JSON lines (banners, blank
  lines) are silently dropped — claude occasionally prints them on stderr,
  which gets folded into stdout via `:stderr_to_stdout` on the Port.
  """
  @spec feed(t(), iodata()) :: {[event()], t()}
  def feed(%__MODULE__{} = parser, chunk) do
    {complete, remainder} = LineBuffer.split(parser.buffer, chunk)
    events = Enum.flat_map(complete, &parse_line/1)
    {events, %{parser | buffer: remainder}}
  end

  @doc """
  Flushes the buffer at port close. If the trailing fragment is a complete
  JSON object (no terminating `\\n`), it is parsed and returned; otherwise
  the fragment is discarded.
  """
  @spec finalize(t()) :: {[event()], t()}
  def finalize(%__MODULE__{} = parser) do
    {lines, remainder} = LineBuffer.take_remainder(parser.buffer)
    {Enum.flat_map(lines, &parse_line/1), %{parser | buffer: remainder}}
  end

  @spec parse_line(binary()) :: [event()]
  defp parse_line(""), do: []

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, map} -> translate(map)
      {:error, _} -> []
    end
  end

  @spec translate(map()) :: [event()]
  defp translate(%{"type" => "system", "subtype" => "init"} = event), do: [{:system_init, event}]

  defp translate(%{"type" => "assistant", "message" => %{"content" => blocks}}) when is_list(blocks) do
    Enum.flat_map(blocks, &translate_assistant_block/1)
  end

  defp translate(%{"type" => "user", "message" => %{"content" => blocks}}) when is_list(blocks) do
    Enum.flat_map(blocks, &translate_user_block/1)
  end

  defp translate(%{"type" => "result"} = result), do: [{:result, result}]

  defp translate(other), do: [{:unknown, other}]

  @spec translate_assistant_block(map()) :: [event()]
  defp translate_assistant_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    [{:assistant_text, text}]
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

  @spec translate_user_block(map()) :: [event()]
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
