defmodule Harness.SafeTerm do
  @moduledoc false

  @doc "Decodes a harness-owned ETF payload, tolerating atoms from another node."
  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_term}
  # sobelow_skip ["Misc.BinToTerm"]
  def decode(payload) when is_binary(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    ArgumentError -> decode_trusted(payload)
  end

  # Harness owns every caller's payload (database blobs or local spill files).
  # The retry is required when :safe rejects a valid atom that this node has not
  # loaded yet; malformed ETF still returns an error.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec decode_trusted(binary()) :: {:ok, term()} | {:error, :invalid_term}
  defp decode_trusted(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
