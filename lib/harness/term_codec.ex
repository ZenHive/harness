defmodule Harness.TermCodec do
  @moduledoc """
  Safe decode + file round-trip for harness-owned Erlang term blobs.

  Every harness persistence layer that round-trips Erlang term binaries it wrote
  itself funnels through this module — `Harness.ResultStore.File` /
  `Harness.ResultStore.Postgres` (run/batch/score payloads),
  `Harness.ProjectRegistry.Persistence` (project payloads), `Harness.Chat.Store`
  (chat sessions), and `Harness.SettingsStore.File` (operator settings). They all
  decode the same way: succeed with the term, or rescue a torn/garbage binary
  into an error tuple rather than letting `ArgumentError` escape.

  ## Why decoding skips `[:safe]`

  Inputs are harness-controlled (written via `term_to_binary` on structs we
  own), not untrusted free text, so the `Misc.BinToTerm` sobelow finding is
  skipped here — at the single shared implementation, not per caller. `[:safe]`
  is deliberately not used: it refuses any term referencing an atom not
  currently interned in the running BEAM, which silently dropped valid records
  written by a prior build (cross-version atom drift on reason/agent/adapter
  atoms). The rescue still catches genuinely torn bytes — they raise
  `ArgumentError` with or without `:safe`.
  """

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
  # Payload is harness-owned term binary written by our own persistence layer —
  # not untrusted input. The rescue still catches torn bytes.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec safe_binary_to_term(binary()) :: {:ok, term()} | {:error, :invalid_term}
  def safe_binary_to_term(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end

  @doc """
  Reads and decodes a harness-owned term file.

  Returns `{:ok, term}`, a `File.read/1` posix error (`{:error, :enoent}`, …),
  or `{:error, {:invalid_term_file, path}}` when the bytes do not decode.
  """
  # Paths are harness-owned storage paths built by the calling store, and the
  # payload is our own term_to_binary output — see the moduledoc.
  # sobelow_skip ["Traversal.FileModule", "Misc.BinToTerm"]
  @spec read_file(Path.t()) :: {:ok, term()} | {:error, term()}
  def read_file(path) do
    with {:ok, body} <- File.read(path) do
      decode_body(body, path)
    end
  end

  @doc """
  Writes a term to `path` via a `.tmp` sibling + atomic rename.

  A concurrent reader never observes a half-written term file, and a crash
  mid-write leaves the old file intact rather than torn. `File.rename/2` is
  atomic on POSIX within one filesystem; the tmp sibling shares the target's
  directory, so the rename stays same-filesystem. Parent directories are
  created as needed.
  """
  # Paths are harness-owned storage paths built by the calling store — see the
  # moduledoc.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_file(Path.t(), term()) :: :ok | {:error, term()}
  def write_file(path, term) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(term)) do
      File.rename(tmp, path)
    end
  end

  @spec decode_body(binary(), Path.t()) :: {:ok, term()} | {:error, {:invalid_term_file, Path.t()}}
  defp decode_body(body, path) do
    case safe_binary_to_term(body) do
      {:ok, term} -> {:ok, term}
      {:error, :invalid_term} -> {:error, {:invalid_term_file, path}}
    end
  end
end
