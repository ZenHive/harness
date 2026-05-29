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

  alias Harness.Dashboard.Transcript.Parser

  defstruct buffer: ""

  @typedoc "Line-buffer carrying any partial trailing bytes between chunks."
  @type t :: %__MODULE__{buffer: binary()}

  @doc "Returns a fresh parser with an empty line buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds an iodata `chunk` and returns `{events, parser}`.

  Complete lines emit zero or more events; partial trailing bytes are held
  until the next chunk supplies the rest. Non-JSON or partially-JSON lines
  emit `{:unknown, %{raw: line}}`.
  """
  @spec feed(t(), iodata()) :: {[Parser.event()], t()}
  def feed(%__MODULE__{} = parser, chunk) do
    combined = parser.buffer <> IO.iodata_to_binary(chunk)
    {complete, remainder} = split_lines(combined)
    events = Enum.flat_map(complete, &parse_line/1)
    {events, %{parser | buffer: remainder}}
  end

  @doc """
  Flushes the buffer at port close. A trailing fragment that happens to be a
  complete JSON object (claude exited without a final newline) is parsed and
  returned; otherwise it is preserved as `:unknown`.
  """
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
