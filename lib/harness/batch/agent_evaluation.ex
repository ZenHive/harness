defmodule Harness.Batch.AgentEvaluation do
  @moduledoc """
  Same-task A/B agent evaluation — fans one roadmap item to N adapters and
  aggregates per-agent quality metrics side by side.

  Built on `Harness.Batch.run_pinned/3` (same fan-out, crash isolation, and
  concurrency cap as a normal batch). Metrics are an additive layer on top of
  the binary pass/fail verification verdict; they never become the verdict.
  """

  alias Harness.Batch
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Run.Result, as: RunResult
  alias Harness.Verification.Verdict

  defmodule Entry do
    @moduledoc """
    Per-agent evaluation metrics for one adapter's attempt on the shared task.

    `verdict` is the verification stack's binary `:pass` / `:fail` (or `nil`
    when verification never ran). No composite score is computed.
    """

    @typedoc "Side-by-side metrics for one adapter on the shared task."
    @type t :: %__MODULE__{
            adapter: module(),
            run_id: String.t(),
            state: RunResult.state(),
            reason: RunResult.reason(),
            verdict: :pass | :fail | nil,
            repair_attempts: non_neg_integer(),
            duration_ms: non_neg_integer() | nil,
            first_attempt_failed_check_count: non_neg_integer(),
            agent_diff_size: non_neg_integer() | nil,
            result: RunResult.t()
          }

    @enforce_keys [
      :adapter,
      :run_id,
      :state,
      :reason,
      :repair_attempts,
      :first_attempt_failed_check_count,
      :result
    ]
    defstruct [
      :adapter,
      :run_id,
      :state,
      :reason,
      :verdict,
      :repair_attempts,
      :duration_ms,
      :first_attempt_failed_check_count,
      :agent_diff_size,
      :result
    ]
  end

  defmodule Comparison do
    @moduledoc """
    Side-by-side evaluation of one roadmap task across several adapters.
    """

    alias Harness.Batch.AgentEvaluation.Entry

    @typedoc "Aggregate comparison for one task evaluated on N adapters."
    @type t :: %__MODULE__{
            batch_id: String.t(),
            task_id: String.t(),
            total: non_neg_integer(),
            max_concurrency: pos_integer(),
            entries: [Entry.t()],
            events: [term()]
          }

    @enforce_keys [:batch_id, :task_id, :total, :max_concurrency, :entries]
    defstruct [:batch_id, :task_id, :total, :max_concurrency, :entries, events: []]
  end

  @doc """
  Dispatches one roadmap item to `adapters` concurrently and returns a comparison.

  Each adapter runs in its own isolated worktree via `Harness.Batch.run_pinned/3`.
  One agent's red or crashed run never aborts the others.
  """
  @spec compare(Item.t(), Project.t() | String.t(), [module()], keyword()) ::
          {:ok, Comparison.t()} | {:error, Batch.error()}
  def compare(%Item{} = item, project, adapters, opts \\ [])
      when is_list(adapters) and adapters != [] and is_list(opts) do
    pairs = Enum.map(adapters, &{item, &1})
    result_store = Keyword.get(opts, :result_store, ResultStore.configured())

    with {:ok, %BatchResult{} = batch} <- Batch.run_pinned(pairs, project, opts) do
      {:ok, from_batch(batch, adapters, result_store)}
    end
  end

  @doc "Builds a comparison from a pinned batch result and the adapter list."
  @spec from_batch(BatchResult.t(), [module()], ResultStore.store()) :: Comparison.t()
  def from_batch(%BatchResult{} = batch, adapters, store) when is_list(adapters) do
    records = records_by_run_id(batch.batch_id, store)

    entries =
      batch.results
      |> Enum.zip(adapters)
      |> Enum.map(fn {result, adapter} -> entry(result, adapter, records) end)

    task_id =
      case batch.results do
        [%RunResult{task_id: task_id} | _] -> task_id
        [] -> "unknown"
      end

    %Comparison{
      batch_id: batch.batch_id,
      task_id: task_id,
      total: batch.total,
      max_concurrency: batch.max_concurrency,
      entries: entries,
      events: batch.events
    }
  end

  @spec records_by_run_id(String.t(), ResultStore.store()) :: %{String.t() => LogRecord.t()}
  defp records_by_run_id(batch_id, store) do
    case ResultStore.list_run_records(store, batch_id: batch_id) do
      {:ok, records} -> Map.new(records, &{&1.run_id, &1})
      {:error, _reason} -> %{}
    end
  end

  @spec entry(RunResult.t(), module(), %{String.t() => LogRecord.t()}) :: Entry.t()
  defp entry(%RunResult{} = result, adapter, records) do
    record = Map.get(records, result.run_id)

    %Entry{
      adapter: adapter,
      run_id: result.run_id,
      state: result.state,
      reason: result.reason,
      verdict: (record && record.verdict) || verdict_status(result),
      repair_attempts: result.repair_attempts,
      duration_ms: record && record.duration_ms,
      first_attempt_failed_check_count: result.first_attempt_failed_check_count,
      agent_diff_size: result.agent_diff_size,
      result: result
    }
  end

  @spec verdict_status(RunResult.t()) :: :pass | :fail | nil
  defp verdict_status(%RunResult{verdict: %Verdict{status: status}}), do: status
  defp verdict_status(_), do: nil
end
