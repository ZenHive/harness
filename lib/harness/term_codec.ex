defmodule Harness.TermCodec do
  @moduledoc """
  Safe wrapper around `:erlang.binary_to_term/1` for harness-owned term blobs.

  Two persistence layers round-trip Erlang term binaries they wrote themselves —
  `Harness.ResultStore.Postgres` (batch payloads) and
  `Harness.ProjectRegistry.Persistence` (project payloads). Both decode the same
  way: succeed with the term, or rescue a torn/garbage binary into
  `{:error, :invalid_term}` rather than letting `ArgumentError` escape.

  The input is harness-controlled (written via `term_to_binary` on structs we
  own), not untrusted free text, so the `Misc.BinToTerm` sobelow finding is
  skipped here — at the single shared implementation, not per caller.
  """

  # Payload is harness-owned term binary written by our own persistence layer —
  # not untrusted input. The rescue still catches torn bytes.
  # sobelow_skip ["Misc.BinToTerm"]
  @doc """
  Decodes a harness-owned term binary.

  Returns `{:ok, term}` on success and `{:error, :invalid_term}` when the binary
  is not a valid serialized term.

  ## Examples

      iex> Harness.TermCodec.safe_binary_to_term(:erlang.term_to_binary(%{a: 1}))
      {:ok, %{a: 1}}

      iex> Harness.TermCodec.safe_binary_to_term(<<0, 1, 2, 3>>)
      {:error, :invalid_term}
  """
  @spec safe_binary_to_term(binary()) :: {:ok, term()} | {:error, :invalid_term}
  def safe_binary_to_term(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
