defmodule Harness.Dashboard.Transcript.Parser.Claude do
  @moduledoc """
  Claude Code (`claude -p --output-format stream-json --verbose`) transcript
  parser — unified-vocab adapter over the wire format
  `Harness.Chat.Claude.StreamParser` already implements (Task 82).

  Each line in claude's stream is one complete JSON object. The wrapper
  line-buffers the same way `StreamParser` does so it can preserve the raw
  bytes of malformed lines as `{:unknown, %{raw: line}}` — `StreamParser`
  silently drops `Jason.decode` failures (its consumer is the Chat backend,
  which does not need raw preservation), so reusing it directly would lose
  the corrupt-line signal Task 86 requires. The Claude-block translation
  itself follows `StreamParser`'s shape verbatim.
  """

  use Harness.Dashboard.Transcript.Parser

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

  defp translate(%{"type" => "result"} = result) do
    [{:system, %{kind: :result, data: result}}]
  end

  defp translate(%{"type" => other} = event) when is_binary(other) do
    [{:system, %{kind: :other, data: Map.put(event, "_type", other)}}]
  end

  defp translate(other), do: [{:unknown, %{raw: Jason.encode!(other)}}]

  # Hand-mapped to bound the atom table — claude emits a churning set of
  # subtype strings across releases (hook_started, hook_response,
  # task_started, task_notification, rate_limit_event, …) and feeding
  # arbitrary LLM-output strings into String.to_atom/1 is a known DoS vector.
  # Unknown subtypes fall through to :other; the raw string survives in
  # `data["subtype"]`.
  @spec system_kind(map()) :: atom()
  defp system_kind(%{"subtype" => "init"}), do: :init
  defp system_kind(%{"subtype" => "hook_started"}), do: :hook_started
  defp system_kind(%{"subtype" => "hook_response"}), do: :hook_response
  defp system_kind(%{"subtype" => "task_started"}), do: :task_started
  defp system_kind(%{"subtype" => "task_notification"}), do: :task_notification
  defp system_kind(%{"subtype" => "rate_limit_event"}), do: :rate_limit_event
  defp system_kind(%{"subtype" => sub}) when is_binary(sub), do: :other
  defp system_kind(_), do: :system
end
