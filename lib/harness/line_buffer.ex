defmodule Harness.LineBuffer do
  @moduledoc """
  Shared newline-buffer lifecycle for the streaming transcript parsers.

  Port chunks from a headless agent split mid-line, so every NDJSON parser
  accumulates a partial-line buffer between chunks and only hands complete
  (newline-terminated) lines to its format-specific decoder. This module owns
  that buffer arithmetic so each parser keeps only its per-line translation:

    * `Harness.Chat.Claude.StreamParser`
    * `Harness.Dashboard.Transcript.Parser.{Claude,Codex,Cursor,Grok,Pi}`

  Pure — operates on a bare string buffer, holds no process, performs no IO.

  ## Usage

      {complete, buffer} = LineBuffer.split(parser.buffer, chunk)
      events = Enum.flat_map(complete, &decode_line/1)
      %{parser | buffer: buffer}

  At Port close the trailing fragment (a final line the agent emitted without
  a terminating newline) is drained with `take_remainder/1`.
  """

  @doc """
  Splits the accumulated `buffer` plus an incoming `chunk` on `"\\n"`.

  Returns `{complete_lines, rest_buffer}`: every newline-terminated line in
  arrival order, and the trailing partial line (held for the next chunk).
  When the combined bytes contain no newline, every byte is buffered and
  `complete_lines` is empty.

  ## Examples

      iex> Harness.LineBuffer.split("", "a\\nb\\nc")
      {["a", "b"], "c"}

      iex> Harness.LineBuffer.split("partial", " line\\ndone")
      {["partial line"], "done"}

      iex> Harness.LineBuffer.split("", "no newline")
      {[], "no newline"}

      iex> Harness.LineBuffer.split("", "ends\\n")
      {["ends"], ""}
  """
  @spec split(binary(), iodata()) :: {[binary()], binary()}
  def split(buffer, chunk) when is_binary(buffer) do
    combined = buffer <> IO.iodata_to_binary(chunk)

    case String.split(combined, "\n") do
      [single] -> {[], single}
      many -> {Enum.drop(many, -1), List.last(many)}
    end
  end

  @doc """
  Drains a leftover `buffer` at Port close.

  Returns `{lines, ""}` where `lines` is `[buffer]` when non-empty (the final
  line the agent emitted without a trailing newline) or `[]` when empty. The
  caller feeds the returned lines through the same per-line decoder it uses
  for `split/2` output.

  ## Examples

      iex> Harness.LineBuffer.take_remainder(~s({"type":"result"}))
      {[~s({"type":"result"})], ""}

      iex> Harness.LineBuffer.take_remainder("")
      {[], ""}
  """
  @spec take_remainder(binary()) :: {[binary()], binary()}
  def take_remainder("" = _buffer), do: {[], ""}
  def take_remainder(buffer) when is_binary(buffer), do: {[buffer], ""}
end
