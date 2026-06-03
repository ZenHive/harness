defmodule Harness.Dashboard.Transcript.Parser.Cursor do
  @moduledoc """
  Cursor (`cursor-agent -p --output-format stream-json`) transcript parser.

  Cursor's NDJSON stream shares Claude's `system/init` + `assistant` (text
  blocks) + `result` envelope, but tool calls and reasoning use a
  Cursor-specific shape rather than Claude's `assistant`/`tool_use` +
  `user`/`tool_result` blocks:

    * `{"type":"tool_call","subtype":"started","call_id":...,"tool_call":{"<kind>ToolCall":{"args":{...}}}}`
      → `{:assistant_tool_use, %{id: call_id, name: "<kind>", input: args}}`.
      The human tool name is the inner key minus its `ToolCall` suffix
      (`readToolCall` → `read`, `editToolCall` → `edit`, …).
    * the matching `subtype: "completed"` event carries the call's output at
      `tool_call.<kind>ToolCall.result` → `{:tool_result, %{tool_use_id: call_id, content: result}}`.
    * `{"type":"thinking","subtype":"delta","text":<fragment>}` streams
      chain-of-thought token-by-token → `{:system, %{kind: :thought, data: %{text: fragment}}}`
      (the same reasoning lane grok uses; the renderer folds consecutive
      fragments into one reasoning card).

  Routing cursor's `tool_call` / `thinking` events through Claude's
  `assistant`/`user` clauses silently bucketed them as `:other` (rendered as
  bare "OTHER" eyebrow rows with no tool card) — so the wire shape is handled
  explicitly here. The `assistant` text and `result` clauses still mirror
  Claude's.
  """

  alias Harness.Dashboard.Transcript.Parser
  alias Harness.LineBuffer

  # Cursor names each tool call by an inner key like `readToolCall` /
  # `editToolCall` / `shellToolCall`; the human tool name is that key minus
  # the suffix (`read` / `edit` / `shell`).
  @tool_call_suffix "ToolCall"

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
    {complete, remainder} = LineBuffer.split(parser.buffer, chunk)
    events = Enum.flat_map(complete, &parse_line/1)
    {events, %{parser | buffer: remainder}}
  end

  @doc "Flushes the buffer at port close — same semantics as `feed/2`."
  @spec finalize(t()) :: {[Parser.event()], t()}
  def finalize(%__MODULE__{} = parser) do
    {lines, remainder} = LineBuffer.take_remainder(parser.buffer)
    {Enum.flat_map(lines, &parse_line/1), %{parser | buffer: remainder}}
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

  defp translate(%{"type" => "tool_call", "subtype" => "started", "tool_call" => tc} = event) do
    {name, args} = tool_call_name_and_args(tc)

    [
      {:assistant_tool_use,
       %{
         id: Map.get(event, "call_id", ""),
         name: name,
         input: args
       }}
    ]
  end

  defp translate(%{"type" => "tool_call", "subtype" => "completed", "tool_call" => tc} = event) do
    [
      {:tool_result,
       %{
         tool_use_id: Map.get(event, "call_id", ""),
         content: tool_call_result(tc)
       }}
    ]
  end

  defp translate(%{"type" => "thinking", "text" => text}) when is_binary(text) do
    [{:system, %{kind: :thought, data: %{text: text}}}]
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

  # Cursor wraps each tool call in a single-key map (`%{"readToolCall" => %{...}}`).
  # The key minus its `ToolCall` suffix is the human tool name; `args` is the
  # call's input. An unexpected shape degrades to a generic name + empty input
  # rather than crashing the parser.
  @spec tool_call_name_and_args(map()) :: {String.t(), map()}
  defp tool_call_name_and_args(tool_call) do
    case Map.to_list(tool_call) do
      [{inner_key, %{} = body}] ->
        {String.replace_suffix(inner_key, @tool_call_suffix, ""), Map.get(body, "args", %{})}

      _ ->
        {"tool", %{}}
    end
  end

  # The `completed` event restates the call wrapper with a `result` field added;
  # surface that result as the tool_result content (the renderer's json tree
  # walks it). Falls back to the whole body when no `result` key is present.
  @spec tool_call_result(map()) :: term()
  defp tool_call_result(tool_call) do
    case Map.to_list(tool_call) do
      [{_inner_key, %{} = body}] -> Map.get(body, "result", body)
      _ -> tool_call
    end
  end
end
