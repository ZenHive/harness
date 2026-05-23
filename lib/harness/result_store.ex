defmodule Harness.ResultStore do
  @moduledoc """
  Pluggable persistence boundary for run logs and batch results.

  The core orchestrator talks only to this behaviour. The default implementation
  is `Harness.ResultStore.File`, keeping persistence file-backed unless callers
  explicitly configure another module.

  ## Best-effort persistence

  Persistence is **best-effort**: `Harness.Run` and `Harness.Batch` invoke
  `record_run/2` and `save_batch/2` on the configured store at settle time,
  log any `{:error, _}` via `Logger.warning/1`, and continue. Neither a
  failed `record_run` nor a failed `save_batch` crashes the run or flips
  `Harness.Batch.run/4`'s `{:ok, result}` to `{:error, _}`. Treat a missing
  record as a degraded observability surface, not a missing verification
  verdict — verdicts come from `Harness.Verification`, not the store.

  Set `config :harness, :result_store, false` (or `nil`) to disable
  persistence entirely; both values short-circuit `record_run`, `save_batch`,
  `load_batch`, and `list_run_records` without dispatching to a backend.
  """

  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Run.LogRecord

  @typedoc "A configured result store module, with optional module-specific options."
  @type store :: module() | {module(), keyword()} | nil | false

  @typedoc "Exact-match filters supported by `list_run_records/2`."
  @type filters :: keyword()

  @doc "Persists one structured run record with implementation-specific options."
  @callback record_run(LogRecord.t(), keyword()) :: :ok | {:error, term()}

  @doc "Persists one finished batch result with implementation-specific options."
  @callback save_batch(BatchResult.t(), keyword()) :: :ok | {:error, term()}

  @doc "Loads one persisted batch result by id."
  @callback load_batch(String.t(), keyword()) :: {:ok, BatchResult.t()} | {:error, term()}

  @doc "Lists persisted run records, optionally filtered by exact field values."
  @callback list_run_records(filters(), keyword()) :: {:ok, [LogRecord.t()]} | {:error, term()}

  @doc "Persists one structured run record."
  @spec record_run(LogRecord.t(), store()) :: :ok | {:error, term()}
  def record_run(record, store \\ configured())

  def record_run(%LogRecord{}, false), do: :ok
  def record_run(%LogRecord{}, nil), do: :ok

  def record_run(%LogRecord{} = record, store) do
    dispatch(store, :record_run, [record])
  end

  @doc "Persists the aggregate result for a finished batch."
  @spec save_batch(BatchResult.t(), store()) :: :ok | {:error, term()}
  def save_batch(result, store \\ configured())

  def save_batch(%BatchResult{}, false), do: :ok
  def save_batch(%BatchResult{}, nil), do: :ok

  def save_batch(%BatchResult{} = result, store) do
    dispatch(store, :save_batch, [result])
  end

  @doc "Loads a previously persisted batch result by id."
  @spec load_batch(String.t(), store()) :: {:ok, BatchResult.t()} | {:error, term()}
  def load_batch(batch_id, store \\ configured())

  def load_batch(batch_id, false) when is_binary(batch_id), do: {:error, :disabled}
  def load_batch(batch_id, nil) when is_binary(batch_id), do: {:error, :disabled}

  def load_batch(batch_id, store) when is_binary(batch_id) do
    dispatch(store, :load_batch, [batch_id])
  end

  @doc "Lists persisted run records, optionally filtered by exact field values."
  @spec list_run_records(filters()) :: {:ok, [LogRecord.t()]} | {:error, term()}
  def list_run_records(filters \\ []) when is_list(filters) do
    list_run_records(configured(), filters)
  end

  @doc "Lists records from an explicit store, optionally filtered by exact field values."
  @spec list_run_records(store(), filters()) :: {:ok, [LogRecord.t()]} | {:error, term()}
  def list_run_records(false, filters) when is_list(filters), do: {:ok, []}
  def list_run_records(nil, filters) when is_list(filters), do: {:ok, []}

  def list_run_records(store, filters) when is_list(filters) do
    dispatch(store, :list_run_records, [filters])
  end

  @doc "Returns the configured result store, defaulting to the file-backed store."
  @spec configured() :: store()
  def configured do
    Application.get_env(:harness, :result_store, {Harness.ResultStore.File, []})
  end

  @spec dispatch(module() | {module(), keyword()}, atom(), [term()]) :: term()
  defp dispatch({module, opts}, function, args) when is_atom(module) and is_list(opts) do
    apply(module, function, args ++ [opts])
  end

  defp dispatch(module, function, args) when is_atom(module) do
    apply(module, function, args ++ [[]])
  end
end
