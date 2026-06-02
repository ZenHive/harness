defmodule Harness.CapabilityScore do
  @moduledoc """
  Per-(agent, domain) capability score computed from benchmark comparisons.

  The score is a persisted routing signal, not a verdict. Inputs are the raw
  metrics already surfaced by `Harness.Batch.AgentEvaluation`: verdict,
  repair attempts, duration, token usage, and first-attempt failed checks.

  ## Composite

  The composite is intentionally success-rate-dominant:

      success_rate * 1000 + bounded_tiebreaker

  The bounded tiebreaker is less than one point and combines token
  `cost_to_green`, mean repair attempts, and mean first-attempt failed checks.
  That keeps success rate as the primary ordering signal while still letting
  cheaper, cleaner runs sort above more expensive ones inside the same success
  cohort. Raw per-run metrics are retained on the score so this formula can be
  retuned without re-running the benchmark corpus.
  """

  alias Harness.AgentRegistry
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.Benchmark.Item
  alias Harness.CapabilityDomain
  alias Harness.ResultStore
  alias Harness.TokenUsage

  @success_scale 1_000
  @cost_scale_tokens 100_000
  @cost_tiebreaker_weight 0.7
  @repair_tiebreaker_weight 0.2
  @first_failure_tiebreaker_weight 0.099
  @freshness_window_days 30
  @seconds_per_day 86_400
  @stale_discount 0.5
  @fallback_agent :claude

  @type freshness :: :fresh | :stale

  defmodule RawMetric do
    @moduledoc """
    One retained per-run input metric used to compute a capability score.
    """

    @type t :: %__MODULE__{
            batch_id: String.t(),
            task_id: String.t(),
            task_version: pos_integer(),
            run_id: String.t(),
            adapter: module(),
            agent: atom() | module(),
            verdict: :pass | :fail | nil,
            repair_attempts: non_neg_integer(),
            duration_ms: non_neg_integer() | nil,
            token_usage: TokenUsage.t(),
            cost_tokens: non_neg_integer(),
            first_attempt_failed_check_count: non_neg_integer()
          }

    @enforce_keys [
      :batch_id,
      :task_id,
      :task_version,
      :run_id,
      :adapter,
      :agent,
      :verdict,
      :repair_attempts,
      :duration_ms,
      :token_usage,
      :cost_tokens,
      :first_attempt_failed_check_count
    ]
    defstruct [
      :batch_id,
      :task_id,
      :task_version,
      :run_id,
      :adapter,
      :agent,
      :verdict,
      :repair_attempts,
      :duration_ms,
      :token_usage,
      :cost_tokens,
      :first_attempt_failed_check_count
    ]
  end

  @typedoc "Persisted capability measurement for one agent/domain/corpus cell."
  @type t :: %__MODULE__{
          agent: atom() | module(),
          domain: CapabilityDomain.t(),
          corpus_version: String.t(),
          scored_at: DateTime.t(),
          run_count: pos_integer(),
          success_rate: float(),
          cost_to_green: float() | nil,
          mean_repair_attempts: float(),
          mean_first_attempt_failed_check_count: float(),
          composite_score: float(),
          raw_metrics: [RawMetric.t()]
        }

  @enforce_keys [
    :agent,
    :domain,
    :corpus_version,
    :scored_at,
    :run_count,
    :success_rate,
    :cost_to_green,
    :mean_repair_attempts,
    :mean_first_attempt_failed_check_count,
    :composite_score,
    :raw_metrics
  ]
  defstruct [
    :agent,
    :domain,
    :corpus_version,
    :scored_at,
    :run_count,
    :success_rate,
    :cost_to_green,
    :mean_repair_attempts,
    :mean_first_attempt_failed_check_count,
    :composite_score,
    :raw_metrics
  ]

  @doc """
  Computes and persists scores for one capability domain.

  Returns one score per measured agent. An empty comparison set returns
  `{:ok, []}`; callers represent a specific unmeasured cell via
  `ResultStore.get_capability_score/4`, which returns `:no_data`.
  """
  @spec score_domain([Comparison.t()], [Item.t()], CapabilityDomain.t(), keyword()) ::
          {:ok, [t()]} | {:error, term()}
  def score_domain(comparisons, corpus_items, domain, opts \\ [])
      when is_list(comparisons) and is_list(corpus_items) and is_atom(domain) and is_list(opts) do
    with {:ok, [domain]} <- CapabilityDomain.validate([domain]) do
      scores =
        comparisons
        |> raw_metrics(corpus_items, domain)
        |> build_scores(domain, opts)

      persist_scores(scores, Keyword.get(opts, :result_store, ResultStore.configured()))
    end
  end

  @doc "Recomputes aggregate metrics and composite from retained raw metrics."
  @spec recompute(t()) :: t()
  def recompute(%__MODULE__{} = score) do
    summarize(score.raw_metrics, score.agent, score.domain, score.corpus_version, score.scored_at)
  end

  @doc "Classifies a persisted capability score as fresh or stale."
  @spec freshness(t(), keyword()) :: freshness()
  def freshness(%__MODULE__{} = score, opts \\ []) when is_list(opts) do
    if score_age_days(score, opts) <= freshness_window_days(opts), do: :fresh, else: :stale
  end

  @doc "Returns the score's routing value after applying stale-score decay."
  @spec discounted_composite_score(t(), keyword()) :: float()
  def discounted_composite_score(%__MODULE__{} = score, opts \\ []) when is_list(opts) do
    case freshness(score, opts) do
      :fresh -> score.composite_score
      :stale -> score.composite_score * stale_discount(opts)
    end
  end

  @doc """
  Lists stale and unmeasured agent/domain cells that need re-benchmarking.

  This is a read-only signal over persisted scores. Stale scores are returned as
  candidates and left intact in the store; the scheduler decides what to re-run.
  """
  @spec rebenchmark_candidates(keyword()) :: {:ok, [map()]} | {:error, term()}
  def rebenchmark_candidates(opts \\ []) when is_list(opts) do
    store = Keyword.get(opts, :result_store, ResultStore.configured())

    with {:ok, scores} <- ResultStore.list_capability_scores(store) do
      {:ok, rebenchmark_candidates(scores, opts)}
    end
  end

  @doc "Pure stale/unmeasured candidate classification over a supplied score list."
  @spec rebenchmark_candidates([t()], keyword()) :: [map()]
  def rebenchmark_candidates(scores, opts) when is_list(scores) and is_list(opts) do
    score_by_cell = latest_score_by_cell(scores, Keyword.get(opts, :corpus_version))

    for domain <- domains(opts),
        agent <- agents(opts),
        candidate = rebenchmark_candidate(agent, domain, score_by_cell, opts),
        not is_nil(candidate) do
      candidate
    end
  end

  @doc """
  Recommends an agent for a capability domain using explore/exploit routing.

  Unmeasured cells become exploration candidates, not low scores. Measured cells
  exploit the best effective score after stale-score discounting.
  """
  @spec recommend(CapabilityDomain.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recommend(domain, opts \\ []) when is_atom(domain) and is_list(opts) do
    store = Keyword.get(opts, :result_store, ResultStore.configured())

    with {:ok, scores} <- ResultStore.list_capability_scores(store) do
      {:ok, recommend_from_scores(domain, scores, opts)}
    end
  end

  @doc "Returns a deterministic corpus-version fingerprint for the supplied items."
  @spec corpus_version([Item.t()]) :: String.t()
  def corpus_version(items) when is_list(items) do
    fingerprint =
      items
      |> Enum.map(fn %Item{id: id, version: version} -> "#{id}:#{version}" end)
      |> Enum.sort()
      |> Enum.join("|")

    :sha256
    |> :crypto.hash(fingerprint)
    |> Base.url_encode64(padding: false)
  end

  @spec raw_metrics([Comparison.t()], [Item.t()], CapabilityDomain.t()) :: [RawMetric.t()]
  defp raw_metrics(comparisons, corpus_items, domain) do
    item_by_id =
      corpus_items
      |> Enum.filter(&(domain in &1.domains))
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(comparisons, fn %Comparison{} = comparison ->
      case Map.fetch(item_by_id, comparison.task_id) do
        {:ok, item} -> Enum.map(comparison.entries, &raw_metric(comparison, item, &1))
        :error -> []
      end
    end)
  end

  @spec raw_metric(Comparison.t(), Item.t(), Entry.t()) :: RawMetric.t()
  defp raw_metric(%Comparison{} = comparison, %Item{} = item, %Entry{} = entry) do
    %RawMetric{
      batch_id: comparison.batch_id,
      task_id: comparison.task_id,
      task_version: item.version,
      run_id: entry.run_id,
      adapter: entry.adapter,
      agent: agent_for_adapter(entry.adapter),
      verdict: entry.verdict,
      repair_attempts: entry.repair_attempts,
      duration_ms: entry.duration_ms,
      token_usage: entry.token_usage,
      cost_tokens: token_total(entry.token_usage),
      first_attempt_failed_check_count: entry.first_attempt_failed_check_count
    }
  end

  @spec build_scores([RawMetric.t()], CapabilityDomain.t(), keyword()) :: [t()]
  defp build_scores(metrics, domain, opts) do
    corpus_version = Keyword.get(opts, :corpus_version) || corpus_version_from_metrics(metrics)
    scored_at = Keyword.get(opts, :scored_at) || DateTime.utc_now()

    metrics
    |> Enum.group_by(& &1.agent)
    |> Enum.map(fn {agent, agent_metrics} ->
      summarize(agent_metrics, agent, domain, corpus_version, scored_at)
    end)
    |> Enum.sort_by(& &1.agent)
  end

  @spec summarize([RawMetric.t()], atom() | module(), CapabilityDomain.t(), String.t(), DateTime.t()) :: t()
  defp summarize(metrics, agent, domain, corpus_version, scored_at) do
    run_count = length(metrics)
    successes = Enum.filter(metrics, &(&1.verdict == :pass))
    success_rate = rate(length(successes), run_count)
    cost_to_green = cost_to_green(successes)
    mean_repair_attempts = mean(Enum.map(metrics, & &1.repair_attempts), run_count)

    mean_first_attempt_failed_check_count =
      mean(Enum.map(metrics, & &1.first_attempt_failed_check_count), run_count)

    %__MODULE__{
      agent: agent,
      domain: domain,
      corpus_version: corpus_version,
      scored_at: scored_at,
      run_count: run_count,
      success_rate: success_rate,
      cost_to_green: cost_to_green,
      mean_repair_attempts: mean_repair_attempts,
      mean_first_attempt_failed_check_count: mean_first_attempt_failed_check_count,
      composite_score:
        composite_score(success_rate, cost_to_green, mean_repair_attempts, mean_first_attempt_failed_check_count),
      raw_metrics: metrics
    }
  end

  @spec persist_scores([t()], ResultStore.store()) :: {:ok, [t()]} | {:error, term()}
  defp persist_scores(scores, store) do
    scores
    |> Enum.reduce_while({:ok, []}, fn score, {:ok, acc} ->
      case ResultStore.save_capability_score(score, store) do
        :ok -> {:cont, {:ok, [score | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, persisted} -> {:ok, Enum.reverse(persisted)}
      error -> error
    end
  end

  @spec recommend_from_scores(CapabilityDomain.t(), [t()], keyword()) :: map()
  defp recommend_from_scores(domain, scores, opts) do
    score_by_cell = latest_score_by_cell(scores, Keyword.get(opts, :corpus_version))
    rows = recommendation_rows(domain, score_by_cell, opts)
    measured = Enum.filter(rows, &(&1.measurement == :measured))
    unmeasured = Enum.filter(rows, &(&1.measurement == :unmeasured))

    cond do
      measured == [] ->
        fallback_recommendation(domain, rows, opts)

      explore_unmeasured?(opts) and unmeasured != [] ->
        explore_recommendation(domain, hd(unmeasured), measured, tl(unmeasured))

      true ->
        exploit_recommendation(domain, measured, unmeasured)
    end
  end

  @spec fallback_recommendation(CapabilityDomain.t(), [map()], keyword()) :: map()
  defp fallback_recommendation(domain, rows, opts) do
    fallback_agent = Keyword.get(opts, :fallback_agent, @fallback_agent)
    selected = Enum.find(rows, &(&1.agent == fallback_agent)) || hd(rows)

    %{
      agent: selected.agent,
      domain: domain,
      strategy: :fallback_no_data,
      rationale: :no_measured_scores,
      ranked: rows
    }
  end

  @spec explore_recommendation(CapabilityDomain.t(), map(), [map()], [map()]) :: map()
  defp explore_recommendation(domain, selected, measured, remaining_unmeasured) do
    %{
      agent: selected.agent,
      domain: domain,
      strategy: :explore,
      rationale: :unmeasured_cell,
      ranked: [selected | measured ++ remaining_unmeasured]
    }
  end

  @spec exploit_recommendation(CapabilityDomain.t(), [map()], [map()]) :: map()
  defp exploit_recommendation(domain, measured, unmeasured) do
    selected = hd(measured)
    rationale = if selected.freshness == :fresh, do: :best_fresh_score, else: :best_discounted_score

    %{
      agent: selected.agent,
      domain: domain,
      strategy: :exploit,
      rationale: rationale,
      ranked: measured ++ unmeasured
    }
  end

  @spec recommendation_rows(CapabilityDomain.t(), map(), keyword()) :: [map()]
  defp recommendation_rows(domain, score_by_cell, opts) do
    {measured, unmeasured} =
      opts
      |> agents()
      |> Enum.map(&recommendation_row(&1, domain, score_by_cell, opts))
      |> Enum.split_with(&(&1.measurement == :measured))

    Enum.sort_by(measured, & &1.effective_score, :desc) ++ unmeasured
  end

  @spec recommendation_row(atom(), CapabilityDomain.t(), map(), keyword()) :: map()
  defp recommendation_row(agent, domain, score_by_cell, opts) do
    case Map.fetch(score_by_cell, {agent, domain}) do
      {:ok, %__MODULE__{} = score} ->
        freshness = freshness(score, opts)

        %{
          agent: agent,
          domain: domain,
          measurement: :measured,
          freshness: freshness,
          score: score.composite_score,
          effective_score: discounted_composite_score(score, opts),
          scored_at: score.scored_at,
          age_days: score_age_days(score, opts),
          corpus_version: score.corpus_version,
          rationale: if(freshness == :fresh, do: :measured_fresh, else: :stale_discounted)
        }

      :error ->
        %{
          agent: agent,
          domain: domain,
          measurement: :unmeasured,
          freshness: :unmeasured,
          score: nil,
          effective_score: nil,
          scored_at: nil,
          age_days: nil,
          corpus_version: Keyword.get(opts, :corpus_version),
          rationale: :explore_unmeasured
        }
    end
  end

  @spec rebenchmark_candidate(atom(), CapabilityDomain.t(), map(), keyword()) :: map() | nil
  defp rebenchmark_candidate(agent, domain, score_by_cell, opts) do
    case Map.fetch(score_by_cell, {agent, domain}) do
      {:ok, %__MODULE__{} = score} ->
        if freshness(score, opts) == :stale do
          %{
            agent: agent,
            domain: domain,
            reason: :stale,
            freshness: :stale,
            scored_at: score.scored_at,
            age_days: score_age_days(score, opts),
            corpus_version: score.corpus_version
          }
        end

      :error ->
        %{
          agent: agent,
          domain: domain,
          reason: :unmeasured,
          freshness: :unmeasured,
          scored_at: nil,
          age_days: nil,
          corpus_version: Keyword.get(opts, :corpus_version)
        }
    end
  end

  @spec latest_score_by_cell([t()], String.t() | nil) :: map()
  defp latest_score_by_cell(scores, corpus_version) do
    scores
    |> Enum.filter(&match_corpus_version?(&1, corpus_version))
    |> Enum.group_by(&{&1.agent, &1.domain})
    |> Map.new(fn {cell, cell_scores} ->
      {cell, Enum.max_by(cell_scores, &DateTime.to_unix(&1.scored_at, :microsecond))}
    end)
  end

  @spec match_corpus_version?(t(), String.t() | nil) :: boolean()
  defp match_corpus_version?(_score, nil), do: true
  defp match_corpus_version?(%__MODULE__{} = score, corpus_version), do: score.corpus_version == corpus_version

  @spec score_age_days(t(), keyword()) :: non_neg_integer()
  defp score_age_days(%__MODULE__{} = score, opts) do
    seconds =
      opts
      |> reference_time()
      |> DateTime.diff(score.scored_at, :second)
      |> max(0)

    div(seconds, @seconds_per_day)
  end

  @spec reference_time(keyword()) :: DateTime.t()
  defp reference_time(opts), do: Keyword.get(opts, :reference_time) || DateTime.utc_now()

  @spec freshness_window_days(keyword()) :: pos_integer()
  defp freshness_window_days(opts), do: Keyword.get(opts, :freshness_window_days, @freshness_window_days)

  @spec stale_discount(keyword()) :: float()
  defp stale_discount(opts), do: Keyword.get(opts, :stale_discount, @stale_discount)

  @spec explore_unmeasured?(keyword()) :: boolean()
  defp explore_unmeasured?(opts), do: Keyword.get(opts, :explore_unmeasured, true)

  @spec agents(keyword()) :: [atom()]
  defp agents(opts), do: Keyword.get(opts, :agents, AgentRegistry.agents() |> Map.keys() |> Enum.sort())

  @spec domains(keyword()) :: [CapabilityDomain.t()]
  defp domains(opts), do: Keyword.get(opts, :domains, CapabilityDomain.domains())

  @spec corpus_version_from_metrics([RawMetric.t()]) :: String.t()
  defp corpus_version_from_metrics(metrics) do
    metrics
    |> Enum.map(fn %RawMetric{task_id: id, task_version: version} -> "#{id}:#{version}" end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join("|")
    |> then(fn fingerprint ->
      :sha256
      |> :crypto.hash(fingerprint)
      |> Base.url_encode64(padding: false)
    end)
  end

  @spec composite_score(float(), float() | nil, float(), float()) :: float()
  defp composite_score(success_rate, cost_to_green, mean_repair_attempts, mean_first_attempt_failed_check_count) do
    success_component = success_rate * @success_scale

    tiebreaker =
      @cost_tiebreaker_weight * cost_efficiency(cost_to_green) +
        @repair_tiebreaker_weight * reciprocal_efficiency(mean_repair_attempts) +
        @first_failure_tiebreaker_weight * reciprocal_efficiency(mean_first_attempt_failed_check_count)

    success_component + tiebreaker
  end

  @spec cost_efficiency(float() | nil) :: float()
  defp cost_efficiency(nil), do: 0.0
  defp cost_efficiency(cost), do: @cost_scale_tokens / (@cost_scale_tokens + cost)

  @spec reciprocal_efficiency(float()) :: float()
  defp reciprocal_efficiency(value), do: 1 / (1 + value)

  @spec cost_to_green([RawMetric.t()]) :: float() | nil
  defp cost_to_green([]), do: nil
  defp cost_to_green(successes), do: mean(Enum.map(successes, & &1.cost_tokens), length(successes))

  @spec rate(non_neg_integer(), pos_integer()) :: float()
  defp rate(count, total) when total > 0, do: count / total

  @spec mean([number()], pos_integer()) :: float()
  defp mean(values, count) when count > 0, do: Enum.sum(values) / count

  @spec token_total(TokenUsage.t()) :: non_neg_integer()
  defp token_total(%TokenUsage{total: total}) when is_integer(total), do: total

  defp token_total(%TokenUsage{} = usage) do
    [usage.input, usage.output, usage.cache_read, usage.cache_creation]
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  @spec agent_for_adapter(module()) :: atom() | module()
  defp agent_for_adapter(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, agent} -> agent
      {:error, _reason} -> adapter
    end
  end
end
