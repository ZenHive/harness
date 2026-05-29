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

  alias Harness.Dashboard.Transcript.Parser

  defstruct buffer: ""

  @typedoc "Line-buffer state."
  @type t :: %__MODULE__{buffer: binary()}

  @doc "Returns a fresh parser."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds an iodata `chunk` and returns `{events, parser}`. Non-JSON lines
  (codex's stderr noise on plugin / panic errors) emit
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
  defp translate(%{"type" => "thread.started"} = event) do
    [{:system, %{kind: :thread_started, data: event}}]
  end

  defp translate(%{"type" => "turn.started"} = event) do
    [{:system, %{kind: :turn_started, data: event}}]
  end

  defp translate(%{"type" => "turn.completed"} = event) do
    [{:system, %{kind: :turn_completed, data: event}}]
  end

  defp translate(%{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}})
       when is_binary(text) do
    [{:assistant_text, %{text: text}}]
  end

  defp translate(%{"type" => "item.started", "item" => %{"type" => "command_execution"} = item}) do
    [
      {:assistant_tool_use,
       %{
         id: Map.get(item, "id", ""),
         name: "command_execution",
         input: %{command: Map.get(item, "command", "")}
       }}
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
