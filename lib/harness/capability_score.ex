defmodule Harness.CapabilityScore do
  @moduledoc """
  Per-(agent, domain) capability score computed from reviewer-gated run comparisons.

  The score is a persisted routing signal, not a verdict. Inputs are the raw
  metrics already surfaced by `Harness.Batch.AgentEvaluation`: the reviewer
  AI's approve/reject verdict, the reviewer's own fix-diff size, duration, and
  token usage.

  ## Composite

  The composite is intentionally success-rate-dominant:

      success_rate * 1000 + bounded_tiebreaker

  The bounded tiebreaker is less than one point and combines the reviewer's
  mean ratings (reviewer-judged quality), token `cost_to_green`, and the mean
  reviewer fix-diff size (how much fixing the reviewer had to do). Because
  rejection is near-never by design, approval rate is nearly constant across
  agents — so the ratings term is what actually moves routing inside a
  same-success cohort, letting `dispatch-recommend` reflect reviewer-judged
  quality rather than approve rate alone. Raw per-run metrics are retained on
  the score so this formula can be retuned without re-running the comparisons.

  ## Scored-set fingerprint (`corpus_version`)

  `corpus_version` survives as the persisted-score key naming *which set of
  tasks* produced the score — now a fingerprint of the compared task ids, not a
  benchmark-corpus version (the mechanical benchmark corpus is deleted; real
  reviewer-gated runs are the measurement substrate).
  """

  alias Harness.AgentKPI
  alias Harness.AgentRegistry
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.CapabilityDomain
  alias Harness.ResultStore
  alias Harness.Run.Review
  alias Harness.TokenUsage

  @success_scale 1_000
  @cost_scale_tokens 100_000
  @ratings_tiebreaker_weight 0.5
  @cost_tiebreaker_weight 0.3
  @reviewer_fix_tiebreaker_weight 0.199
  @rating_scale 10.0
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
            run_id: String.t(),
            adapter: module(),
            agent: atom() | module(),
            verdict: Review.verdict() | nil,
            reviewer_diff_size: non_neg_integer() | nil,
            duration_ms: non_neg_integer() | nil,
            token_usage: TokenUsage.t(),
            cost_tokens: non_neg_integer(),
            ratings: %{optional(String.t()) => term()}
          }

    @enforce_keys [
      :batch_id,
      :task_id,
      :run_id,
      :adapter,
      :agent,
      :verdict,
      :reviewer_diff_size,
      :duration_ms,
      :token_usage,
      :cost_tokens
    ]
    defstruct [
      :batch_id,
      :task_id,
      :run_id,
      :adapter,
      :agent,
      :verdict,
      :reviewer_diff_size,
      :duration_ms,
      :token_usage,
      :cost_tokens,
      ratings: %{}
    ]
  end

  @typedoc "Persisted capability measurement for one agent/domain/scored-set cell."
  @type t :: %__MODULE__{
          agent: atom() | module(),
          domain: CapabilityDomain.t(),
          corpus_version: String.t(),
          scored_at: DateTime.t(),
          run_count: pos_integer(),
          success_rate: float(),
          cost_to_green: float() | nil,
          mean_reviewer_diff_size: float(),
          mean_ratings: %{optional(String.t()) => float()},
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
    :mean_reviewer_diff_size,
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
    :mean_reviewer_diff_size,
    :composite_score,
    :raw_metrics,
    mean_ratings: %{}
  ]

  @doc """
  Computes and persists scores for one capability domain.

  The caller scopes `comparisons` to the domain (e.g. via the compared tasks'
  domain tags); every entry in every comparison is measured. Returns one score
  per measured agent. An empty comparison set returns `{:ok, []}`; callers
  represent a specific unmeasured cell via `ResultStore.get_capability_score/4`,
  which returns `:no_data`.
  """
  @spec score_domain([Comparison.t()], CapabilityDomain.t(), keyword()) ::
          {:ok, [t()]} | {:error, term()}
  def score_domain(comparisons, domain, opts \\ []) when is_list(comparisons) and is_atom(domain) and is_list(opts) do
    with {:ok, [domain]} <- CapabilityDomain.validate([domain]) do
      scores =
        comparisons
        |> raw_metrics()
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

  @spec raw_metrics([Comparison.t()]) :: [RawMetric.t()]
  defp raw_metrics(comparisons) do
    Enum.flat_map(comparisons, fn %Comparison{} = comparison ->
      Enum.map(comparison.entries, &raw_metric(comparison, &1))
    end)
  end

  @spec raw_metric(Comparison.t(), Entry.t()) :: RawMetric.t()
  defp raw_metric(%Comparison{} = comparison, %Entry{} = entry) do
    %RawMetric{
      batch_id: comparison.batch_id,
      task_id: comparison.task_id,
      run_id: entry.run_id,
      adapter: entry.adapter,
      agent: agent_for_adapter(entry.adapter),
      verdict: entry.verdict,
      reviewer_diff_size: entry.reviewer_diff_size,
      duration_ms: entry.duration_ms,
      token_usage: entry.token_usage,
      cost_tokens: token_total(entry.token_usage),
      ratings: entry_ratings(entry)
    }
  end

  # Tolerates a pre-rating Entry whose struct predates the field (Map.get -> nil).
  @spec entry_ratings(Entry.t()) :: %{optional(String.t()) => term()}
  defp entry_ratings(entry), do: Map.get(entry, :ratings) || %{}

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
    successes = Enum.filter(metrics, &(&1.verdict == :approve))
    success_rate = rate(length(successes), run_count)
    cost_to_green = cost_to_green(successes)
    mean_reviewer_diff_size = mean(Enum.map(metrics, &(&1.reviewer_diff_size || 0)), run_count)
    mean_ratings = AgentKPI.rating_means(Enum.map(metrics, &entry_ratings/1))

    %__MODULE__{
      agent: agent,
      domain: domain,
      corpus_version: corpus_version,
      scored_at: scored_at,
      run_count: run_count,
      success_rate: success_rate,
      cost_to_green: cost_to_green,
      mean_reviewer_diff_size: mean_reviewer_diff_size,
      mean_ratings: mean_ratings,
      composite_score: composite_score(success_rate, cost_to_green, mean_reviewer_diff_size, mean_ratings),
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
    |> Enum.map(fn %RawMetric{task_id: id} -> id end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join("|")
    |> then(fn fingerprint ->
      :sha256
      |> :crypto.hash(fingerprint)
      |> Base.url_encode64(padding: false)
    end)
  end

  @spec composite_score(float(), float() | nil, float(), %{optional(String.t()) => float()}) :: float()
  defp composite_score(success_rate, cost_to_green, mean_reviewer_diff_size, mean_ratings) do
    success_component = success_rate * @success_scale

    tiebreaker =
      @ratings_tiebreaker_weight * ratings_efficiency(mean_ratings) +
        @cost_tiebreaker_weight * cost_efficiency(cost_to_green) +
        @reviewer_fix_tiebreaker_weight * reciprocal_efficiency(mean_reviewer_diff_size)

    success_component + tiebreaker
  end

  # Reviewer-judged quality as a [0,1] tiebreaker: the overall mean rating
  # (across the reviewer's free-form keys) normalized against a 10-point scale.
  # No rating reported contributes 0.0, so an unrated cohort sorts purely on
  # the cost / reviewer-fix terms — never penalized below a rated one's floor.
  @spec ratings_efficiency(%{optional(String.t()) => float()}) :: float()
  defp ratings_efficiency(mean_ratings) when map_size(mean_ratings) == 0, do: 0.0

  defp ratings_efficiency(mean_ratings) do
    values = Map.values(mean_ratings)
    overall = Enum.sum(values) / length(values)

    overall |> Kernel./(@rating_scale) |> min(1.0) |> max(0.0)
  end

  @spec cost_efficiency(float() | nil) :: float()
  defp cost_efficiency(nil), do: 0.0
  defp cost_efficiency(cost), do: @cost_scale_tokens / (@cost_scale_tokens + cost)

  @spec reciprocal_efficiency(float()) :: float()
  defp reciprocal_efficiency(value), do: 1 / (1 + value)

  # Mean total tokens across an agent's reviewer-approved runs.
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
