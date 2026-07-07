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

  use Harness.Dashboard.Transcript.Parser

  # Cursor names each tool call by an inner key like `readToolCall` /
  # `editToolCall` / `shellToolCall`; the human tool name is that key minus
  # the suffix (`read` / `edit` / `shell`).
  @tool_call_suffix "ToolCall"

  @spec translate(map()) :: [Parser.event()]
  defp translate(%{"type" => "system", "subtype" => "init"} = event) do
    [{:system, %{kind: :init, data: event}}]
  end

  defp translate(%{"type" => "system"} = event) do
    [{:system, %{kind: system_kind(event), data: event}}]
  end

  defp translate(%{"type" => "assistant", "message" => %{"content" => blocks}}) when is_list(blocks) do
    Enum.flat_map(blocks, &Parser.translate_assistant_block/1)
  end

  defp translate(%{"type" => "user", "message" => %{"content" => blocks}}) when is_list(blocks) do
    Enum.flat_map(blocks, &Parser.translate_user_block/1)
  end

  defp translate(%{"type" => "tool_call", "subtype" => "started", "tool_call" => tc} = event) do
    {name, args} = tool_call_name_and_args(tc)

    [
      {:assistant_tool_use, Parser.assistant_tool_use_payload(tool_call_id(event, tc), name, args)}
    ]
  end

  defp translate(%{"type" => "tool_call", "subtype" => "completed", "tool_call" => tc} = event) do
    [
      {:tool_result,
       %{
         tool_use_id: tool_call_id(event, tc),
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

  # Cursor wraps each tool call in a map keyed by the real tool payload
  # (`%{"readToolCall" => %{...}}`) plus metadata siblings such as
  # `hookAdditionalContexts` and `toolCallId`. The key minus its `ToolCall`
  # suffix is the human tool name; `args` is the call's input. An unexpected
  # shape degrades to a generic name + empty input rather than crashing.
  @spec tool_call_name_and_args(map()) :: {String.t(), map()}
  defp tool_call_name_and_args(tool_call) do
    case tool_call_entry(tool_call) do
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
    case tool_call_entry(tool_call) do
      [{_inner_key, %{} = body}] -> Map.get(body, "result", body)
      _ -> tool_call
    end
  end

  @spec tool_call_entry(map()) :: [{String.t(), map()}]
  defp tool_call_entry(tool_call) do
    tool_call
    |> Map.to_list()
    |> Enum.filter(fn
      {key, %{} = _body} -> String.ends_with?(key, @tool_call_suffix)
      _entry -> false
    end)
    |> Enum.take(1)
  end

  @spec tool_call_id(map(), map()) :: String.t()
  defp tool_call_id(event, tool_call) do
    Map.get(event, "call_id") || Map.get(event, "toolCallId") || Map.get(tool_call, "toolCallId") || ""
  end
end
