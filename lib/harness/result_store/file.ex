defmodule Harness.ResultStore.File do
  @moduledoc """
  File-backed `Harness.ResultStore` implementation.

  Records are stored as Erlang external terms under a root directory. That keeps
  the store dependency-free and reloadable after the harness process exits while
  still exposing query functions that return structured Elixir records.
  """

  @behaviour Harness.ResultStore

  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Run.LogRecord

  require Logger

  @default_root "~/.harness/results"

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: :ok | {:error, term()}
  def record_run(%LogRecord{} = record, opts) when is_list(opts) do
    write_term(run_path(record.run_id, opts), record)
  end

  @impl Harness.ResultStore
  @spec save_batch(BatchResult.t(), keyword()) :: :ok | {:error, term()}
  def save_batch(%BatchResult{} = result, opts) when is_list(opts) do
    write_term(batch_path(result.batch_id, opts), result)
  end

  @impl Harness.ResultStore
  @spec load_batch(String.t(), keyword()) :: {:ok, BatchResult.t()} | {:error, term()}
  def load_batch(batch_id, opts) when is_binary(batch_id) and is_list(opts) do
    path = batch_path(batch_id, opts)

    case read_term(path) do
      {:ok, %BatchResult{} = result} -> {:ok, result}
      {:ok, _other} -> {:error, {:invalid_term_file, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Harness.ResultStore
  @spec list_run_records(Harness.ResultStore.filters(), keyword()) :: {:ok, [LogRecord.t()]} | {:error, term()}
  def list_run_records(filters, opts) when is_list(filters) and is_list(opts) do
    dir = Path.join(root(opts), "runs")

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".term"))
        |> Enum.map(&read_term(Path.join(dir, &1)))
        |> collect_records(filters)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Skips are counted, not logged per-file: a single corrupt-looking file used to
  # emit one Logger.warning on EVERY scan (dashboard / mix harness.status all funnel
  # here), spamming the console. An `:undecodable` skip means genuinely torn bytes —
  # near-impossible, since writes are atomic (.tmp + rename) and only *.term is read.
  # A `:cross_typed` skip is a file that decoded fine but to some other term, not a
  # %LogRecord{}. Either way the file is left in place (NOT quarantined or deleted)
  # and at most one aggregated :debug line is emitted per scan.
  @spec collect_records([{:ok, term()} | {:error, term()}], Harness.ResultStore.filters()) ::
          {:ok, [LogRecord.t()]}
  defp collect_records(records, filters) do
    {kept, skipped} =
      Enum.reduce(records, {[], %{cross_typed: 0, undecodable: 0}}, fn
        {:ok, %LogRecord{} = record}, {acc, skip} ->
          if match_filters?(record, filters), do: {[record | acc], skip}, else: {acc, skip}

        {:ok, _other}, {acc, skip} ->
          {acc, Map.update!(skip, :cross_typed, &(&1 + 1))}

        {:error, _reason}, {acc, skip} ->
          {acc, Map.update!(skip, :undecodable, &(&1 + 1))}
      end)

    log_skipped(skipped)
    {:ok, Enum.reverse(kept)}
  end

  @spec log_skipped(%{cross_typed: non_neg_integer(), undecodable: non_neg_integer()}) :: :ok
  defp log_skipped(%{cross_typed: 0, undecodable: 0}), do: :ok

  defp log_skipped(%{cross_typed: cross, undecodable: undecodable}) do
    Logger.debug(fn ->
      "harness result store: skipped #{cross + undecodable} term file(s) " <>
        "(#{undecodable} undecodable/corrupt; #{cross} cross-typed non-record). " <>
        "Files left in place."
    end)
  end

  @spec match_filters?(LogRecord.t(), Harness.ResultStore.filters()) :: boolean()
  defp match_filters?(%LogRecord{} = record, filters) do
    Enum.all?(filters, fn {key, value} -> Map.get(record, key) == value end)
  end

  @spec write_term(String.t(), term()) :: :ok | {:error, term()}
  # Paths are built internally by storage_path/2 from an expanded root plus
  # base64url-encoded ids, then checked to stay under that root.
  #
  # Write to a sibling `.tmp` then atomically rename it into place: a concurrent
  # reader (list_run_records reading the runs/ dir) never observes a half-written
  # term file, and a crash mid-write leaves the old file intact rather than torn.
  # rename/2 is atomic on POSIX within one filesystem; the tmp sibling shares the
  # target's directory, so the rename stays same-filesystem.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_term(path, term) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(term)) do
      File.rename(tmp, path)
    end
  end

  @spec read_term(String.t()) :: {:ok, term()} | {:error, term()}
  # Decodes WITHOUT [:safe]: these are harness-owned files written by this app's
  # own term_to_binary under the store root — not untrusted input. [:safe] refuses
  # any term referencing an atom not currently interned in the running BEAM, which
  # silently dropped valid records written by a prior build (cross-version atom
  # drift on reason/agent/adapter atoms). The rescue still catches genuinely torn
  # bytes — they raise ArgumentError with or without :safe.
  # sobelow_skip ["Traversal.FileModule", "Misc.BinToTerm"]
  defp read_term(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, :erlang.binary_to_term(body)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, {:invalid_term_file, path}}
  end

  @spec run_path(String.t(), keyword()) :: String.t()
  defp run_path(run_id, opts) do
    storage_path(opts, ["runs", safe_id(run_id) <> ".term"])
  end

  @spec batch_path(String.t(), keyword()) :: String.t()
  defp batch_path(batch_id, opts) do
    storage_path(opts, ["batches", safe_id(batch_id) <> ".term"])
  end

  @spec storage_path(keyword(), [String.t()]) :: String.t()
  defp storage_path(opts, segments) do
    root = root(opts)
    path = Path.expand(Path.join([root | segments]))
    root_with_separator = root <> "/"

    if path == root or String.starts_with?(path, root_with_separator) do
      path
    else
      raise ArgumentError, "result store path escaped root"
    end
  end

  @spec safe_id(String.t()) :: String.t()
  defp safe_id(id) do
    Base.url_encode64(id, padding: false)
  end

  @spec root(keyword()) :: String.t()
  defp root(opts) do
    opts
    |> Keyword.get(:root, configured_root() || @default_root)
    |> Path.expand()
  end

  @spec configured_root() :: String.t() | nil
  defp configured_root do
    case Application.get_env(:harness, :result_store) do
      {__MODULE__, opts} when is_list(opts) -> opts[:root]
      _other -> nil
    end
  end
end
