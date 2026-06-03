defmodule Harness.ResultStore.File do
  @moduledoc """
  File-backed `Harness.ResultStore` implementation.

  Records are stored as Erlang external terms under a root directory. That keeps
  the store dependency-free and reloadable after the harness process exits while
  still exposing query functions that return structured Elixir records.
  """

  @behaviour Harness.ResultStore

  alias Harness.AgentKPI
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore
  alias Harness.Run.LogRecord
  alias Harness.TermCodec

  require Logger

  @default_root "~/.harness/results"

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: :ok | {:error, term()}
  def record_run(%LogRecord{} = record, opts) when is_list(opts) do
    TermCodec.write_file(run_path(record.run_id, opts), record)
  end

  @impl Harness.ResultStore
  @spec save_batch(BatchResult.t(), keyword()) :: :ok | {:error, term()}
  def save_batch(%BatchResult{} = result, opts) when is_list(opts) do
    TermCodec.write_file(batch_path(result.batch_id, opts), result)
  end

  @impl Harness.ResultStore
  @spec load_batch(String.t(), keyword()) :: {:ok, BatchResult.t()} | {:error, term()}
  def load_batch(batch_id, opts) when is_binary(batch_id) and is_list(opts) do
    path = batch_path(batch_id, opts)

    case TermCodec.read_file(path) do
      {:ok, %BatchResult{} = result} -> {:ok, result}
      {:ok, _other} -> {:error, {:invalid_term_file, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Harness.ResultStore
  @spec list_run_records(Harness.ResultStore.filters(), keyword()) :: {:ok, [LogRecord.t()]} | {:error, term()}
  def list_run_records(filters, opts) when is_list(filters) and is_list(opts) do
    {limit, filters} = Harness.ResultStore.pop_limit(filters)
    point_lookup? = Keyword.has_key?(filters, :run_id)
    dir = Path.join(root(opts), "runs")

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".term"))
        |> Enum.map(&read_run_entry(dir, &1))
        |> collect_records(filters, point_lookup?: point_lookup?, limit: limit)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Harness.ResultStore
  @spec aggregate_by_agent(keyword(), keyword()) :: {:ok, AgentKPI.t()} | {:error, term()}
  def aggregate_by_agent(_query_opts, opts) when is_list(opts) do
    case list_run_records([], opts) do
      {:ok, records} -> {:ok, AgentKPI.aggregate(records)}
      {:error, _} = err -> err
    end
  end

  @spec read_run_entry(String.t(), String.t()) :: {:ok, term(), integer()} | {:error, term()}
  defp read_run_entry(dir, file) do
    path = Path.join(dir, file)

    case {TermCodec.read_file(path), File.stat(path, time: :posix)} do
      {{:ok, term}, {:ok, %File.Stat{mtime: mtime}}} -> {:ok, term, mtime}
      {{:error, _} = err, _} -> err
      {_, {:error, _} = err} -> err
    end
  end

  @impl Harness.ResultStore
  @spec save_capability_score(CapabilityScore.t(), keyword()) :: :ok | {:error, term()}
  def save_capability_score(%CapabilityScore{} = score, opts) when is_list(opts) do
    TermCodec.write_file(capability_score_path(score.agent, score.domain, score.corpus_version, opts), score)
  end

  @impl Harness.ResultStore
  @spec get_capability_score(atom(), atom(), String.t(), keyword()) ::
          {:ok, CapabilityScore.t()} | :no_data | {:error, term()}
  def get_capability_score(agent, domain, corpus_version, opts)
      when is_atom(agent) and is_atom(domain) and is_binary(corpus_version) and is_list(opts) do
    path = capability_score_path(agent, domain, corpus_version, opts)

    case TermCodec.read_file(path) do
      {:ok, %CapabilityScore{} = score} -> {:ok, score}
      {:ok, _other} -> {:error, {:invalid_term_file, path}}
      {:error, :enoent} -> :no_data
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Harness.ResultStore
  @spec list_capability_scores(keyword()) :: {:ok, [CapabilityScore.t()]} | {:error, term()}
  def list_capability_scores(opts) when is_list(opts) do
    dir = storage_path(opts, ["capability_scores"])

    case File.ls(dir) do
      {:ok, files} ->
        scores =
          files
          |> Enum.filter(&String.ends_with?(&1, ".term"))
          |> Enum.flat_map(&decode_score(Path.join(dir, &1)))
          |> Enum.sort_by(&{&1.domain, &1.agent, &1.corpus_version})

        {:ok, scores}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Decodes one persisted score file; anything that isn't a %CapabilityScore{} is skipped.
  @spec decode_score(String.t()) :: [CapabilityScore.t()]
  defp decode_score(path) do
    case TermCodec.read_file(path) do
      {:ok, %CapabilityScore{} = score} -> [score]
      _other -> []
    end
  end

  # Skips are counted, not logged per-file: a single corrupt-looking file used to
  # emit one Logger.warning on EVERY scan (dashboard / mix harness.status all funnel
  # here), spamming the console. An `:undecodable` skip means genuinely torn bytes —
  # near-impossible, since writes are atomic (.tmp + rename) and only *.term is read.
  # A `:cross_typed` skip is a file that decoded fine but to some other term, not a
  # %LogRecord{}. Either way the file is left in place (NOT quarantined or deleted)
  # and at most one aggregated :debug line is emitted per scan.
  @spec collect_records(
          [{:ok, term(), integer()} | {:error, term()}],
          Harness.ResultStore.filters(),
          keyword()
        ) :: {:ok, [LogRecord.t()]}
  defp collect_records(records, filters, opts) do
    point_lookup? = Keyword.get(opts, :point_lookup?, false)
    limit = Keyword.get(opts, :limit)

    {kept, skipped} =
      Enum.reduce(records, {[], %{cross_typed: 0, undecodable: 0}}, fn
        {:ok, %LogRecord{} = record, mtime}, {acc, skip} ->
          record = maybe_strip_agent_output(record, point_lookup?)

          if match_filters?(record, filters),
            do: {[{record, mtime} | acc], skip},
            else: {acc, skip}

        {:ok, _other, _mtime}, {acc, skip} ->
          {acc, Map.update!(skip, :cross_typed, &(&1 + 1))}

        {:error, _reason}, {acc, skip} ->
          {acc, Map.update!(skip, :undecodable, &(&1 + 1))}
      end)

    log_skipped(skipped)

    kept =
      kept
      |> Enum.sort_by(fn {_record, mtime} -> mtime end, :desc)
      |> Enum.map(fn {record, _mtime} -> record end)
      |> maybe_take(limit)

    {:ok, kept}
  end

  @spec maybe_strip_agent_output(LogRecord.t(), boolean()) :: LogRecord.t()
  defp maybe_strip_agent_output(%LogRecord{} = record, true), do: record

  defp maybe_strip_agent_output(%LogRecord{} = record, false) do
    %{record | agent_output: ""}
  end

  @spec maybe_take([LogRecord.t()], pos_integer() | nil) :: [LogRecord.t()]
  defp maybe_take(records, nil), do: records
  defp maybe_take(records, limit) when is_integer(limit), do: Enum.take(records, limit)

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

  @spec run_path(String.t(), keyword()) :: String.t()
  defp run_path(run_id, opts) do
    storage_path(opts, ["runs", safe_id(run_id) <> ".term"])
  end

  @spec batch_path(String.t(), keyword()) :: String.t()
  defp batch_path(batch_id, opts) do
    storage_path(opts, ["batches", safe_id(batch_id) <> ".term"])
  end

  @spec capability_score_path(atom(), atom(), String.t(), keyword()) :: String.t()
  defp capability_score_path(agent, domain, corpus_version, opts) do
    storage_path(opts, ["capability_scores", safe_score_key(agent, domain, corpus_version) <> ".term"])
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

  @spec safe_score_key(atom(), atom(), String.t()) :: String.t()
  defp safe_score_key(agent, domain, corpus_version) do
    {agent, domain, corpus_version}
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
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
