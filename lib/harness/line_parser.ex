defmodule Harness.LineParser do
  @moduledoc """
  Line-buffered NDJSON parsing shared by every agent stream parser.

  All structured agent CLIs (claude, codex, cursor, grok, pi) emit
  newline-delimited JSON on their Ports, and every parser needs the same
  plumbing: hold partial trailing bytes between chunks (`Harness.LineBuffer`),
  `Jason.decode/1` each completed line, and hand the decoded object — or the
  undecodable raw line — to a parser-specific translation.

  This module is that plumbing, vocabulary-agnostic: callers supply a
  `translate` fun for decoded objects and an `on_invalid` fun for lines that
  fail JSON decoding, and decide themselves what an "event" is.
  `Harness.Dashboard.Transcript.Parser`'s `__using__` macro and
  `Harness.Chat.Claude.StreamParser` are the two consumers.
  """

  alias Harness.LineBuffer

  @typedoc "One parsed event — the concrete shape is the caller's vocabulary."
  @type event :: term()

  @typedoc "Translates one decoded JSON object into zero or more events."
  @type translate :: (map() -> [event()])

  @typedoc "Handles a completed line that failed JSON decoding."
  @type on_invalid :: (String.t() -> [event()])

  @doc """
  Feeds an iodata `chunk` against `buffer` and returns `{events, remainder}`.

  Complete lines are decoded and translated in arrival order; partial trailing
  bytes are returned as the new buffer remainder to carry into the next chunk.
  """
  @spec feed(binary(), iodata(), translate(), on_invalid()) :: {[event()], binary()}
  def feed(buffer, chunk, translate, on_invalid) when is_binary(buffer) do
    {complete, remainder} = LineBuffer.split(buffer, chunk)
    {Enum.flat_map(complete, &parse_line(&1, translate, on_invalid)), remainder}
  end

  @doc """
  Flushes `buffer` at port close and returns `{events, remainder}`.

  A trailing fragment that became a complete line without a terminating newline
  (the agent process exited without one) is decoded and translated like any
  other line.
  """
  @spec finalize(binary(), translate(), on_invalid()) :: {[event()], binary()}
  def finalize(buffer, translate, on_invalid) when is_binary(buffer) do
    {lines, remainder} = LineBuffer.take_remainder(buffer)
    {Enum.flat_map(lines, &parse_line(&1, translate, on_invalid)), remainder}
  end

  @spec parse_line(binary(), translate(), on_invalid()) :: [event()]
  defp parse_line("", _translate, _on_invalid), do: []

  defp parse_line(line, translate, on_invalid) do
    case Jason.decode(line) do
      {:ok, decoded} -> translate.(decoded)
      {:error, _} -> on_invalid.(line)
    end
  end
end
