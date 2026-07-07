defmodule Harness.Dashboard.Transcript.Parser.Codex do
  @moduledoc """
  Codex (`codex exec --json`) transcript parser.

  Codex's NDJSON stream uses an `item` envelope with dot-notation event
  types — `thread.started`, `turn.started`, `item.started`, `item.completed`,
  `turn.completed`. Each `item` carries its own `type` (`agent_message`,
  `command_execution`, `reasoning`, …) and the event surface walks both the
  outer envelope type and the inner item type.

  Codex's binary also occasionally emits non-JSON log lines on stderr
  (plugin-load errors, panic messages); `:stderr_to_stdout` on the Port
  folds them into the captured stream. Those lines emit
  `{:unknown, %{raw: line}}` — never silently dropped.

  Mapped event types:

    * `thread.started` / `turn.started` / `turn.completed` →
      `{:system, %{kind: :thread_started | :turn_started | :turn_completed, data: event}}`
    * `item.completed` with `item.type == "agent_message"` →
      `{:assistant_text, %{text: item.text}}`
    * `item.started` / `item.completed` with `item.type == "command_execution"` →
      `{:assistant_tool_use, %{id: item.id, name: "command_execution", input: %{command: ...}}}`
      followed by `{:tool_result, %{tool_use_id: item.id, content: aggregated_output}}`
      on `completed`
    * everything else with a recognised type → `{:system, %{kind: :other, data: event}}`
  """

  use Harness.Dashboard.Transcript.Parser

  @spec translate(map()) :: [Parser.event()]
  defp translate(%{"type" => "thread.started"} = event) do
    [{:system, %{kind: :thread_started, data: event}}]
  end

  defp translate(%{"type" => "turn.started"} = event) do
    [{:system, %{kind: :turn_started, data: event}}]
  end

  defp translate(%{"type" => "turn.completed"} = event) do
    [{:system, %{kind: :turn_completed, data: event}}]
  end

  # Each `agent_message` item is a *complete* intermediate message, not a token
  # delta. The renderer folds consecutive `:assistant_text` into one block
  # (right for grok's token-by-token stream), which would otherwise run codex's
  # distinct messages together into one wall of text. A trailing blank line
  # keeps them visually separated once folded.
  defp translate(%{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}})
       when is_binary(text) do
    [{:assistant_text, %{text: text <> "\n\n"}}]
  end

  defp translate(%{"type" => "item.started", "item" => %{"type" => "command_execution"} = item}) do
    [
      {:assistant_tool_use,
       Parser.assistant_tool_use_payload(Map.get(item, "id", ""), "command_execution", %{
         command: Map.get(item, "command", "")
       })}
    ]
  end

  defp translate(%{"type" => "item.completed", "item" => %{"type" => "command_execution"} = item}) do
    [
      {:tool_result,
       %{
         tool_use_id: Map.get(item, "id", ""),
         content: %{
           aggregated_output: Map.get(item, "aggregated_output", ""),
           exit_code: Map.get(item, "exit_code"),
           status: Map.get(item, "status")
         }
       }}
    ]
  end

  defp translate(%{"type" => other} = event) when is_binary(other) do
    [{:system, %{kind: :other, data: Map.put(event, "_type", other)}}]
  end

  defp translate(other), do: [{:unknown, %{raw: Jason.encode!(other)}}]
end
