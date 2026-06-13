defmodule Harness.Batch.AgentEvaluation do
  @moduledoc """
  Same-task A/B agent evaluation — fans one roadmap item to N adapters and
  aggregates per-agent quality metrics side by side.

  Built on `Harness.Batch.run_pinned/3` (same fan-out, crash isolation, and
  concurrency cap as a normal batch). Metrics are an additive layer on top of
  the reviewer AI's approve/reject verdict; they never become the verdict.
  """

  use Descripex, namespace: "/batch/agent_evaluation"

  alias Harness.AgentAdapter
  alias Harness.AgentKPI
  alias Harness.AgentRegistry
  alias Harness.Batch
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Config
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Run.Result, as: RunResult
  alias Harness.Run.Review
  alias Harness.TokenUsage

  defmodule Entry do
    @moduledoc """
    Per-agent evaluation metrics for one adapter's attempt on the shared task.

    `verdict` is the reviewer AI's `:approve` / `:reject` decision (or `nil`
    when the run never reached review). No composite score is computed.

    `reviewer_diff_size` is the changed-line count of the reviewer's own fixes
    on top of the implementer's delivery — `0` + `:approve` means the work
    needed no fixes (first-attempt pass).

    `token_usage` is the `Harness.TokenUsage` parsed from the adapter's raw
    transcript (summed across dispatches) — the efficiency signal that
    lets an A/B comparison weigh *how many tokens* an adapter spent, not only
    whether it was approved. An empty usage (all-`nil`) means the wire format
    reported no token counts.

    `ratings` is the reviewer AI's free-form quality scores for this attempt
    (`review_skills` scores, falling back to legacy `review_ratings`, persisted on the run record).
    The scout's per-facet assessment reads these facts grouped by reviewer
    `review_facets`; routing never fuses them into a composite scalar.
    """

    @typedoc "Side-by-side metrics for one adapter on the shared task."
    @type t :: %__MODULE__{
            adapter: module(),
            run_id: String.t(),
            state: RunResult.state(),
            reason: RunResult.reason(),
            verdict: Review.verdict() | nil,
            reviewer_diff_size: non_neg_integer() | nil,
            duration_ms: non_neg_integer() | nil,
            agent_diff_size: non_neg_integer() | nil,
            token_usage: TokenUsage.t(),
            ratings: %{optional(String.t()) => term()},
            result: RunResult.t()
          }

    @enforce_keys [
      :adapter,
      :run_id,
      :state,
      :reason,
      :result
    ]
    defstruct [
      :adapter,
      :run_id,
      :state,
      :reason,
      :verdict,
      :reviewer_diff_size,
      :duration_ms,
      :agent_diff_size,
      :result,
      token_usage: %TokenUsage{},
      ratings: %{}
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

  api(
    :compare,
    "Same-task A/B agent evaluation — dispatch one roadmap item to N adapters concurrently and aggregate side-by-side metrics.",
    params: [
      item: [
        kind: :exchange_data,
        source: "Harness.Roadmap.ingest/2",
        description: "Single %Harness.Roadmap.Item{} to evaluate across adapters."
      ],
      project: [
        kind: :exchange_data,
        source: "Harness.ProjectRegistry.lookup/1",
        description: "%Harness.Project{} or registered project name string."
      ],
      adapters: [
        kind: :value,
        description: "Non-empty list of adapter modules (e.g. [Harness.AgentAdapter.Claude, Harness.AgentAdapter.Codex])."
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Forwarded to Harness.Batch.run_pinned/3 (max_concurrency, required_capabilities, env). Optional :models maps adapter names to per-adapter model pins."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Comparison{batch_id, task_id, total, max_concurrency, entries, events}} — entries holds per-adapter %Entry{} metrics (verdict :approve|:reject|nil, reviewer_diff_size, duration_ms, agent_diff_size, token_usage). {:error, Batch.error()}."
    }
  )

  @spec compare(Item.t(), Project.t() | String.t(), [module()], keyword()) ::
          {:ok, Comparison.t()} | {:error, Batch.error() | term()}
  def compare(%Item{} = item, project, adapters, opts \\ [])
      when is_list(adapters) and adapters != [] and is_list(opts) do
    models = Keyword.get(opts, :models, %{})
    run_opts = Keyword.delete(opts, :models)
    result_store = Keyword.get(opts, :result_store, ResultStore.configured())

    with {:ok, pairs} <- pairs_with_models(item, adapters, models),
         {:ok, %BatchResult{} = batch} <- Batch.run_pinned(pairs, project, run_opts) do
      {:ok, from_batch(batch, adapters, result_store)}
    end
  end

  @spec pairs_with_models(Item.t(), [module()], map()) :: {:ok, [{Item.t(), module()}]} | {:error, term()}
  defp pairs_with_models(%Item{} = item, adapters, models) when is_map(models) do
    adapters
    |> Enum.reduce_while({:ok, []}, fn adapter, {:ok, pairs} ->
      case item_with_model(item, adapter, models) do
        {:ok, modeled} -> {:cont, {:ok, [{modeled, adapter} | pairs]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  defp pairs_with_models(%Item{}, _adapters, models), do: {:error, {:invalid_models, models}}

  @spec item_with_model(Item.t(), module(), map()) :: {:ok, Item.t()} | {:error, term()}
  defp item_with_model(%Item{} = item, adapter, models) do
    with {:ok, model} <- compare_model(adapter, models),
         :ok <- validate_model(adapter, model) do
      {:ok, %{item | model: model}}
    end
  end

  @spec compare_model(module(), map()) :: {:ok, String.t() | nil} | {:error, term()}
  defp compare_model(adapter, models) do
    case model_override(adapter, models) do
      {:ok, model} -> {:ok, model}
      :error -> default_model(adapter)
      {:error, _reason} = error -> error
    end
  end

  @spec model_override(module(), map()) :: {:ok, String.t()} | :error | {:error, term()}
  defp model_override(adapter, models) do
    adapter
    |> model_keys()
    |> Enum.find_value(:error, &model_override_for_key(&1, models, adapter))
  end

  @spec model_override_for_key(term(), map(), module()) ::
          {:ok, String.t()} | :error | {:error, term()} | nil
  defp model_override_for_key(key, models, adapter) do
    if Map.has_key?(models, key), do: model_override_value(Map.fetch!(models, key), adapter)
  end

  @spec model_override_value(term(), module()) :: {:ok, String.t()} | {:error, term()}
  defp model_override_value(model, _adapter) when is_binary(model), do: {:ok, model}

  defp model_override_value(other, adapter), do: {:error, {:invalid_model, model_error_target(adapter), other}}

  @spec model_keys(module()) :: [term()]
  defp model_keys(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, agent} -> [Atom.to_string(agent), agent, adapter]
      {:error, _reason} -> [adapter]
    end
  end

  @spec default_model(module()) :: {:ok, String.t() | nil}
  defp default_model(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, agent} -> {:ok, Config.agent_model(agent)}
      {:error, _reason} -> {:ok, nil}
    end
  end

  @spec validate_model(module(), term()) :: :ok | {:error, term()}
  defp validate_model(adapter, nil) do
    if AgentAdapter.requires_model?(adapter) do
      {:error, {:model_required, model_error_target(adapter)}}
    else
      :ok
    end
  end

  defp validate_model(adapter, model) when is_binary(model) do
    if AgentAdapter.model_supported?(adapter, model) do
      :ok
    else
      {:error, {:invalid_model_for_adapter, adapter, model}}
    end
  end

  @spec model_error_target(module()) :: atom() | module()
  defp model_error_target(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, agent} -> agent
      {:error, _reason} -> adapter
    end
  end

  api(
    :from_batch,
    "Build a Comparison from a previously-completed pinned batch result and the adapter list it was dispatched with.",
    params: [
      batch: [
        kind: :value,
        description:
          "%Harness.Batch.Result{} returned by Harness.Batch.run_pinned/3. Caller-held; reconstruct from ResultStore.load_batch/1 if persisted."
      ],
      adapters: [
        kind: :value,
        description:
          "List of adapter modules — MUST have the same length as batch.results (the i-th adapter is attached to the i-th result). Raises ArgumentError on length mismatch."
      ],
      store: [
        kind: :value,
        description:
          "ResultStore reference (Harness.ResultStore.configured() or override). Used to look up per-run records for richer entry metrics."
      ]
    ],
    returns: %{
      type: :map,
      description: "%Comparison{batch_id, task_id, total, max_concurrency, entries, events}."
    },
    errors: [argument_error: "Raised when length(adapters) != length(batch.results)."]
  )

  @spec from_batch(BatchResult.t(), [module()], ResultStore.store()) :: Comparison.t()
  def from_batch(%BatchResult{} = batch, adapters, store) when is_list(adapters) do
    results_count = length(batch.results)
    adapters_count = length(adapters)

    if results_count != adapters_count do
      raise ArgumentError,
            "AgentEvaluation.from_batch/3 requires batch.results and adapters to have equal length; " <>
              "got #{results_count} results and #{adapters_count} adapters"
    end

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
      verdict: (record && record.verdict) || review_verdict(result),
      reviewer_diff_size: entry_reviewer_diff_size(record, result),
      duration_ms: record && record.duration_ms,
      agent_diff_size: result.agent_diff_size,
      token_usage: entry_token_usage(record, result),
      ratings: entry_ratings(record),
      result: result
    }
  end

  # The reviewer's quality scores live only on the persisted record. Current
  # records use review_skills; legacy pre-rubric records use review_ratings.
  @spec entry_ratings(LogRecord.t() | nil) :: %{optional(String.t()) => term()}
  defp entry_ratings(record), do: AgentKPI.record_ratings(record)

  # Prefers the persisted record's measured usage, falling back to the live
  # result's (always a `%TokenUsage{}`, empty when unmeasured). `Map.get/2`
  # tolerates a pre-token persisted record whose term predates the field
  # (returns nil) — never a crash.
  @spec entry_token_usage(LogRecord.t() | nil, RunResult.t()) :: TokenUsage.t()
  defp entry_token_usage(record, result) do
    record_usage = record && Map.get(record, :token_usage)

    if match?(%TokenUsage{}, record_usage) and TokenUsage.measured?(record_usage) do
      record_usage
    else
      result.token_usage
    end
  end

  @spec review_verdict(RunResult.t()) :: Review.verdict() | nil
  defp review_verdict(%RunResult{review: %Review{verdict: verdict}}), do: verdict
  defp review_verdict(_), do: nil

  # Prefers the persisted record's measurement; a record predating the field
  # (Map.get -> nil) falls back to the live result's.
  @spec entry_reviewer_diff_size(LogRecord.t() | nil, RunResult.t()) :: non_neg_integer() | nil
  defp entry_reviewer_diff_size(record, result) do
    record_size = record && Map.get(record, :reviewer_diff_size)
    if is_integer(record_size), do: record_size, else: result.reviewer_diff_size
  end
end
