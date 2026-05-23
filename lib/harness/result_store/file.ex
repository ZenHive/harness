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
    batch_id |> batch_path(opts) |> read_term()
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

  @spec collect_records([{:ok, LogRecord.t()} | {:error, term()}], Harness.ResultStore.filters()) ::
          {:ok, [LogRecord.t()]} | {:error, term()}
  defp collect_records(records, filters) do
    records
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, %LogRecord{} = record}, {:ok, acc} ->
        if match_filters?(record, filters) do
          {:cont, {:ok, [record | acc]}}
        else
          {:cont, {:ok, acc}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec match_filters?(LogRecord.t(), Harness.ResultStore.filters()) :: boolean()
  defp match_filters?(%LogRecord{} = record, filters) do
    Enum.all?(filters, fn {key, value} -> Map.get(record, key) == value end)
  end

  @spec write_term(String.t(), term()) :: :ok | {:error, term()}
  # Paths are built internally by storage_path/2 from an expanded root plus
  # base64url-encoded ids, then checked to stay under that root.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_term(path, term) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, :erlang.term_to_binary(term))
    end
  end

  @spec read_term(String.t()) :: {:ok, term()} | {:error, term()}
  # Paths are root-contained as above. Term decoding uses [:safe] and only reads
  # harness-owned files from the configured store root.
  # sobelow_skip ["Traversal.FileModule", "Misc.BinToTerm"]
  defp read_term(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, :erlang.binary_to_term(body, [:safe])}
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
