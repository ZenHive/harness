defmodule Harness.Text do
  @moduledoc """
  Byte-level text helpers shared across run prompts and diff capping.

  `binary_part/3` truncation can split a multi-byte UTF-8 codepoint at either
  end of the kept slice; `valid_utf8_head/1` and `valid_utf8_tail/1` repair the
  cut by dropping at most 3 bytes (the longest UTF-8 continuation run) from the
  damaged edge. `placeholder/1` renders absent prompt sections as a literal
  `"(none)"`.
  """

  @doc """
  Trims trailing bytes from `bin` until it is valid UTF-8.

  Repairs a head slice (`binary_part(text, 0, cap)`) that cut mid-codepoint.

  ## Examples

      iex> Harness.Text.valid_utf8_head(binary_part("ahé", 0, 3))
      "ah"
  """
  @spec valid_utf8_head(binary()) :: binary()
  def valid_utf8_head(<<>>), do: <<>>

  def valid_utf8_head(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_head(binary_part(bin, 0, byte_size(bin) - 1))
  end

  @doc """
  Drops leading bytes from `bin` until it is valid UTF-8.

  Repairs a tail slice (`binary_part(text, size - cap, cap)`) that cut
  mid-codepoint.

  ## Examples

      iex> Harness.Text.valid_utf8_tail(binary_part("héllo", 2, 4))
      "llo"
  """
  @spec valid_utf8_tail(binary()) :: binary()
  def valid_utf8_tail(<<>>), do: <<>>

  def valid_utf8_tail(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_tail(binary_part(bin, 1, byte_size(bin) - 1))
  end

  @doc """
  Coalesces `nil` / empty text to the literal `"(none)"` for prompt rendering.

  ## Examples

      iex> Harness.Text.placeholder("diff --stat output")
      "diff --stat output"
  """
  @spec placeholder(String.t() | nil) :: String.t()
  def placeholder(nil), do: "(none)"
  def placeholder(""), do: "(none)"
  def placeholder(text) when is_binary(text), do: text
end
