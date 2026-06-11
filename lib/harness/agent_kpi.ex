defmodule Harness.AgentKPI do
  @moduledoc """
  Per-agent KPI rollup over the run records `Harness.ResultStore` already persists.

  This context adds **no new capture** — every input field (`agent`, `verdict`,
  `duration_ms`, `token_usage`, `review_iterations`, `review_skills` /
  `review_ratings`,
  `reviewer_adapter`, `domains`) is already on `Harness.Run.LogRecord`. It is a
  read-only aggregation that makes the data we already have viewable at a
  glance: roll a record list up by `agent` into success rate,
  first-attempt-pass rate, duration median/p90, mean tokens, mean review
  iterations, the reviewer's mean ratings, and a cost-to-green composite.
  `aggregate_by_agent_domain/1` adds the same rollup keyed by `{agent, domain}`
  for per-domain slicing.

  ## Ceremony / fragmentation tax (`aggregate_ceremony_cost/1`)

  `aggregate_ceremony_cost/1` counts the per-dispatch token overhead of the
  implement→review→audit pipeline for reviewer-approved runs (`:approve` +
  `:done`). Implementer spend comes from the persisted `token_usage`; reviewer
  spend is parsed from `reviewer_output` via `Harness.TokenUsage` (requires the
  transcript — use `include_transcripts: true` when listing from
  `Harness.ResultStore`). Post-merge audit spend is **not** on run records today,
  so `audit` is reported as `0` until audit capture lands — the breakdown is
  still honest raw counting, not a batching verdict.

  ## Reviewer-as-gate rollup

  `aggregate_reviewer_rejections/1` is the mirror-image view: keyed by
  `reviewer_adapter` (the cross-family reviewer that gated the run), it reports
  each reviewer's rejection rate **and** its verdict-write reliability. Since
  rejection is near-never by design, a reviewer with an outlier rejection rate
  is one signal; `no_verdict_rate` is the other — the fraction of gated runs
  the reviewer ended without writing `.harness/review.json` (a
  `{:review_stuck, _}` reason). Both let cross-family selection deprioritize a
  reviewer that rejects too freely or flakes on the mandatory final write.

  ## Reviewer-flaked attribution

  A `{:review_stuck, _}` run is the *reviewer's* failure, not the implementer's:
  the implementer exited fine and the reviewer produced no verdict artifact. So
  it is partitioned out of the implementer's `success_rate` /
  `first_attempt_pass_rate` denominator (`attributable_count = run_count -
  reviewer_flaked`) and surfaced as a separate `reviewer_flaked` count.
  Attribution is keyed mechanically on the persisted `reason` field — no
  classifier, no "whose fault" heuristic.

  ## Pure by construction

  `aggregate/1` does no I/O — the caller supplies the record set (typically from
  `Harness.ResultStore.list_run_records/1`), so the rollup is testable without a
  store. Aggregates are recomputed on read, never persisted.

  ## Conventions

    * A `verdict` of `:approve` (the reviewer AI's decision) is a success;
      `:reject` and `nil` (the run never reached review) both count as
      non-successes in the denominators, **except** a `{:review_stuck, _}` run,
      which is excluded from the implementer's denominator entirely (the
      reviewer, not the implementer, failed it).
    * Token means treat an unreported (`nil`) component as `0` and divide by the
      agent's full run count. In practice reporting is all-or-nothing per agent
      (a plain-text adapter reports none), so this matches the per-agent rollup.
    * `cost_to_green` is the mean total tokens across an agent's `:approve` runs;
      an agent with zero `:approve` runs reports `nil` (no divide-by-zero, not `0`).
  """

  alias Harness.AgentRegistry
  alias Harness.CapabilityDomain
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  @typedoc "Median and 90th-percentile (nearest-rank) of an agent's run durations."
  @type duration_summary :: %{median: number(), p90: non_neg_integer()}

  @typedoc "Mean tokens per run for an agent, by component."
  @type token_means :: %{input: float(), output: float(), total: float()}

  @typedoc "Mean of each reviewer quality-score key (the keys are the reviewer's, free-form)."
  @type rating_means :: %{optional(String.t()) => float()}

  @typedoc "Rolled-up KPIs for one agent."
  @type agent_kpi :: %{
          run_count: pos_integer(),
          reviewer_flaked: non_neg_integer(),
          success_rate: float(),
          first_attempt_pass_rate: float(),
          duration_ms: duration_summary(),
          tokens: token_means(),
          review_iterations: float(),
          ratings: rating_means(),
          cost_to_green: float() | nil
        }

  @typedoc """
  Rejection + verdict-write reliability metrics for one reviewer adapter acting
  AS the gate. `no_verdict_count` is the reviewer's `{:review_stuck, _}` runs
  (gated but no `.harness/review.json` written); `no_verdict_rate` is that over
  the reviews it gated.
  """
  @type reviewer_rejection :: %{
          reviewed_count: pos_integer(),
          rejection_count: non_neg_integer(),
          rejection_rate: float(),
          no_verdict_count: non_neg_integer(),
          no_verdict_rate: float()
        }

  @typedoc "Per-reviewer-adapter rejection ledger keyed by the reviewer module."
  @type reviewer_ledger :: %{optional(module()) => reviewer_rejection()}

  @typedoc "Known orchestration-health causes for `{:review_stuck, detail}` records."
  @type review_stuck_cause ::
          :reviewer_unavailable
          | :no_cross_family_reviewer
          | :same_family_reviewer
          | :reviewer_crashed
          | :driver_crashed
          | :timed_out
          | :cancelled
          | :other

  @typedoc "Review-stuck orchestration-health counts by persisted cause."
  @type review_stuck_causes :: %{optional(review_stuck_cause()) => non_neg_integer()}

  @typedoc "Per-agent ledger keyed by the record's `agent` atom (or `nil` for an unregistered adapter)."
  @type t :: %{optional(atom() | nil) => agent_kpi()}

  @typedoc "Per-(agent, domain) ledger keyed by `{agent, domain}`."
  @type by_agent_domain :: %{optional({atom() | nil, CapabilityDomain.bucket()}) => agent_kpi()}

  @typedoc "Token spend by ceremony stage for one approved run."
  @type ceremony_breakdown :: %{
          implementer: non_neg_integer(),
          reviewer: non_neg_integer(),
          audit: non_neg_integer()
        }

  @typedoc "Per-run ceremony total keyed by task and run ids."
  @type ceremony_entry :: %{
          task_id: String.t(),
          run_id: String.t(),
          total: non_neg_integer(),
          tokens: ceremony_breakdown()
        }

  @typedoc "Median and p90 over a list of per-run ceremony token totals."
  @type ceremony_distribution :: %{
          total: duration_summary(),
          implementer: duration_summary(),
          reviewer: duration_summary(),
          audit: duration_summary()
        }

  @typedoc "Raw ceremony-cost facts over reviewer-approved runs — no batching verdict."
  @type ceremony_cost :: %{
          run_count: non_neg_integer(),
          per_task: [ceremony_entry()],
          distribution: ceremony_distribution()
        }

  @doc """
  Rolls a list of `Harness.Run.LogRecord` up into a per-agent KPI ledger.

  Returns a map keyed by each record's `agent`; an empty input returns `%{}`.
  """
  @spec aggregate([LogRecord.t()]) :: t()
  def aggregate(records) when is_list(records) do
    records
    |> Enum.group_by(& &1.agent)
    |> Map.new(fn {agent, group} -> {agent, summarize(group)} end)
  end

  @doc """
  Rolls records up by `{agent, domain}` for per-domain KPI slicing.

  Records with multiple domain tags contribute to each tag's bucket. Untagged
  records bucket under `{agent, :untagged}` and are never dropped.
  """
  @spec aggregate_by_agent_domain([LogRecord.t()]) :: by_agent_domain()
  def aggregate_by_agent_domain(records) when is_list(records) do
    records
    |> Enum.flat_map(&agent_domain_pairs/1)
    |> Enum.group_by(fn {key, _record} -> key end, fn {_key, record} -> record end)
    |> Map.new(fn {key, group} -> {key, summarize(group)} end)
  end

  @spec agent_domain_pairs(LogRecord.t()) :: [{{atom() | nil, CapabilityDomain.bucket()}, LogRecord.t()}]
  defp agent_domain_pairs(record) do
    record
    |> LogRecord.domains()
    |> CapabilityDomain.buckets()
    |> Enum.map(fn domain -> {{record.agent, domain}, record} end)
  end

  @spec summarize([LogRecord.t()]) :: agent_kpi()
  defp summarize(records) do
    run_count = length(records)
    reviewer_flaked = Enum.count(records, &review_stuck?/1)
    # The reviewer, not the implementer, failed a review_stuck run, so exclude it
    # from the implementer's success denominator (never from run_count, a fact).
    attributable_count = run_count - reviewer_flaked
    passes = Enum.filter(records, &(&1.verdict == :approve))
    durations = records |> Enum.map(& &1.duration_ms) |> Enum.sort()

    %{
      run_count: run_count,
      reviewer_flaked: reviewer_flaked,
      success_rate: rate(length(passes), attributable_count),
      first_attempt_pass_rate: rate(first_attempt_passes(records), attributable_count),
      duration_ms: %{median: median(durations), p90: percentile(durations, 90)},
      tokens: token_means(records, run_count),
      review_iterations: mean(Enum.map(records, & &1.review_iterations), run_count),
      ratings: rating_means(Enum.map(records, &record_ratings/1)),
      cost_to_green: cost_to_green(passes)
    }
  end

  @doc """
  Counts per-run ceremony token spend over reviewer-approved records.

  Each `:approve` + `:done` record yields one `per_task` entry (implementer +
  reviewer + audit components). Post-merge audit tokens are not persisted on run
  records, so `tokens.audit` is `0` until audit capture exists. The
  `distribution` block is median/p90 over the per-run totals and each
  component — raw facts only, no batching recommendation.
  """
  @spec aggregate_ceremony_cost([LogRecord.t()]) :: ceremony_cost()
  def aggregate_ceremony_cost(records) when is_list(records) do
    entries =
      records
      |> Enum.filter(&ceremony_eligible?/1)
      |> Enum.map(&ceremony_entry/1)

    %{
      run_count: length(entries),
      per_task: entries,
      distribution: ceremony_distribution(entries)
    }
  end

  @doc """
  Returns implementer, reviewer, and audit token totals for one run record.

  Reviewer spend is parsed from `reviewer_output` when present; audit is `0`
  (not on run records).
  """
  @spec ceremony_tokens(LogRecord.t()) :: ceremony_breakdown()
  def ceremony_tokens(%LogRecord{} = record) do
    %{
      implementer: token_total(record.token_usage),
      reviewer: reviewer_token_total(record),
      audit: 0
    }
  end

  @doc """
  Rolls records up by `reviewer_adapter` into a per-reviewer rejection ledger.

  Only records the reviewer actually gated count toward the denominator —
  `reviewer_adapter` set and either a non-nil `verdict` or a
  `{:review_stuck, _}` reason (the reviewer ran but wrote no verdict). A
  reviewer's `rejection_rate` is its `:reject` verdicts over those gated runs;
  `no_verdict_rate` is its `{:review_stuck, _}` runs over the same — its
  verdict-write reliability. An empty input returns `%{}`.
  """
  @spec aggregate_reviewer_rejections([LogRecord.t()]) :: reviewer_ledger()
  def aggregate_reviewer_rejections(records) when is_list(records) do
    records
    |> Enum.filter(&reviewed?/1)
    |> Enum.group_by(&reviewer_adapter/1)
    |> Map.new(fn {reviewer, group} -> {reviewer, summarize_reviewer(group)} end)
  end

  @doc """
  Counts `{:review_stuck, detail}` records by their persisted orchestration cause.

  This is a harness-health rollup, not reviewer attribution: selection-time
  stuck runs with `reviewer_adapter: nil` are included because the cause lives
  in the persisted `reason` fact.
  """
  @spec aggregate_review_stuck_causes([LogRecord.t()]) :: review_stuck_causes()
  def aggregate_review_stuck_causes(records) when is_list(records) do
    records
    |> Enum.map(&review_stuck_cause/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  @doc """
  Means each numeric rating key across a list of the reviewer's `ratings` maps.

  The reviewer's keys and scales are free-form, so every numeric-valued key is
  meaned independently over the maps that actually carry it. Non-numeric values
  and absent keys are ignored (never counted as `0`); no rating reported
  returns `%{}`.
  """
  @spec rating_means([map()]) :: rating_means()
  def rating_means(ratings_maps) when is_list(ratings_maps) do
    ratings_maps
    |> Enum.flat_map(&numeric_ratings/1)
    |> Enum.group_by(fn {key, _value} -> key end, fn {_key, value} -> value end)
    |> Map.new(fn {key, values} -> {key, Enum.sum(values) / length(values)} end)
  end

  @spec numeric_ratings(term()) :: [{String.t(), number()}]
  defp numeric_ratings(map) when is_map(map) do
    for {key, value} <- map, is_number(value), do: {to_string(key), value}
  end

  defp numeric_ratings(_other), do: []

  @doc false
  @spec record_ratings(LogRecord.t() | map() | nil) :: %{optional(String.t()) => number()}
  def record_ratings(nil), do: %{}

  def record_ratings(record) when is_map(record) do
    skills = record_field(record, :review_skills)
    ratings = record_field(record, :review_ratings)

    if non_empty_map?(skills) do
      rating_scores(skills)
    else
      rating_scores(ratings)
    end
  end

  @spec record_field(map(), atom()) :: term()
  defp record_field(record, field), do: Map.get(record, field) || Map.get(record, Atom.to_string(field))

  @spec non_empty_map?(term()) :: boolean()
  defp non_empty_map?(value), do: is_map(value) and map_size(value) > 0

  @spec rating_scores(term()) :: %{optional(String.t()) => number()}
  defp rating_scores(block) when is_map(block) do
    for {key, value} <- block,
        score = quality_score(value),
        is_number(score),
        into: %{},
        do: {to_string(key), score}
  end

  defp rating_scores(_other), do: %{}

  @spec quality_score(term()) :: number() | nil
  defp quality_score(value) when is_number(value), do: value

  defp quality_score(value) when is_map(value) do
    Map.get(value, "score") || Map.get(value, :score)
  end

  defp quality_score(_other), do: nil

  @spec reviewed?(LogRecord.t()) :: boolean()
  defp reviewed?(record) do
    not is_nil(reviewer_adapter(record)) and
      (record_verdict(record) in [:approve, :reject] or review_stuck?(record))
  end

  # A run the reviewer ended without writing a verdict artifact — keyed purely
  # on the persisted `reason` fact, no inference.
  @spec review_stuck?(LogRecord.t()) :: boolean()
  defp review_stuck?(record), do: match?({:review_stuck, _report}, Map.get(record, :reason))

  @spec review_stuck_cause(LogRecord.t()) :: review_stuck_cause() | nil
  defp review_stuck_cause(record) do
    case Map.get(record, :reason) do
      {:review_stuck, detail} -> stuck_cause(detail)
      _other -> nil
    end
  end

  @spec stuck_cause(term()) :: review_stuck_cause()
  defp stuck_cause(detail) when is_tuple(detail) and tuple_size(detail) > 0 do
    detail
    |> elem(0)
    |> stuck_cause()
  end

  defp stuck_cause(cause) when cause in [:reviewer_unavailable, :no_cross_family_reviewer, :same_family_reviewer] do
    cause
  end

  defp stuck_cause("Reviewer crashed: :killed"), do: :reviewer_crashed

  defp stuck_cause(report) when is_binary(report) do
    cond do
      String.contains?(report, "{:reviewer_unavailable,") -> :reviewer_unavailable
      String.contains?(report, "{:no_cross_family_reviewer,") -> :no_cross_family_reviewer
      String.contains?(report, "{:same_family_reviewer,") -> :same_family_reviewer
      true -> :other
    end
  end

  defp stuck_cause(:reviewer_crashed), do: :reviewer_crashed
  defp stuck_cause(:driver_crashed), do: :driver_crashed
  defp stuck_cause(:timed_out), do: :timed_out
  defp stuck_cause(:cancelled), do: :cancelled
  defp stuck_cause(_other), do: :other

  @spec reviewer_adapter(LogRecord.t()) :: module() | nil
  defp reviewer_adapter(record), do: Map.get(record, :reviewer_adapter)

  @spec record_verdict(LogRecord.t()) :: atom() | nil
  defp record_verdict(record), do: Map.get(record, :verdict)

  @spec summarize_reviewer([LogRecord.t()]) :: reviewer_rejection()
  defp summarize_reviewer(records) do
    reviewed_count = length(records)
    rejection_count = Enum.count(records, &(record_verdict(&1) == :reject))
    no_verdict_count = Enum.count(records, &review_stuck?/1)

    %{
      reviewed_count: reviewed_count,
      rejection_count: rejection_count,
      rejection_rate: rejection_count / reviewed_count,
      no_verdict_count: no_verdict_count,
      no_verdict_rate: no_verdict_count / reviewed_count
    }
  end

  @spec ceremony_eligible?(LogRecord.t()) :: boolean()
  defp ceremony_eligible?(record) do
    record.verdict == :approve and record.state == :done
  end

  @spec ceremony_entry(LogRecord.t()) :: ceremony_entry()
  defp ceremony_entry(record) do
    tokens = ceremony_tokens(record)

    %{
      task_id: record.task_id,
      run_id: record.run_id,
      total: ceremony_total(tokens),
      tokens: tokens
    }
  end

  @spec ceremony_total(ceremony_breakdown()) :: non_neg_integer()
  defp ceremony_total(tokens) do
    tokens.implementer + tokens.reviewer + tokens.audit
  end

  @spec ceremony_distribution([ceremony_entry()]) :: ceremony_distribution()
  defp ceremony_distribution([]) do
    empty = %{median: 0, p90: 0}

    %{
      total: empty,
      implementer: empty,
      reviewer: empty,
      audit: empty
    }
  end

  defp ceremony_distribution(entries) do
    %{
      total: duration_summary(Enum.map(entries, & &1.total)),
      implementer: duration_summary(Enum.map(entries, & &1.tokens.implementer)),
      reviewer: duration_summary(Enum.map(entries, & &1.tokens.reviewer)),
      audit: duration_summary(Enum.map(entries, & &1.tokens.audit))
    }
  end

  @spec reviewer_token_total(LogRecord.t()) :: non_neg_integer()
  defp reviewer_token_total(record) do
    output = Map.get(record, :reviewer_output) || ""

    record
    |> Map.get(:reviewer_adapter)
    |> reviewer_agent_kind()
    |> then(&token_total(TokenUsage.parse(&1, output)))
  end

  @spec reviewer_agent_kind(module() | nil) :: TokenUsage.agent_kind()
  defp reviewer_agent_kind(nil), do: nil

  defp reviewer_agent_kind(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, agent} -> agent
      {:error, _reason} -> nil
    end
  end

  @spec token_total(TokenUsage.t() | nil) :: non_neg_integer()
  defp token_total(%TokenUsage{} = usage) do
    case Map.get(usage, :total) do
      count when is_integer(count) -> count
      _ -> Enum.sum(Enum.filter([usage.input, usage.output, usage.cache_read, usage.cache_creation], &is_integer/1))
    end
  end

  defp token_total(_other), do: 0

  @spec first_attempt_passes([LogRecord.t()]) :: non_neg_integer()
  defp first_attempt_passes(records) do
    Enum.count(records, &(&1.verdict == :approve and &1.review_iterations == 0))
  end

  @spec token_means([LogRecord.t()], pos_integer()) :: token_means()
  defp token_means(records, run_count) do
    %{
      input: mean(Enum.map(records, &token_field(&1, :input)), run_count),
      output: mean(Enum.map(records, &token_field(&1, :output)), run_count),
      total: mean(Enum.map(records, &token_field(&1, :total)), run_count)
    }
  end

  # An unreported (nil) or absent component contributes 0 to the mean.
  @spec token_field(LogRecord.t(), :input | :output | :total) :: non_neg_integer()
  defp token_field(%LogRecord{token_usage: %TokenUsage{} = usage}, field) do
    case Map.get(usage, field) do
      count when is_integer(count) -> count
      _ -> 0
    end
  end

  defp token_field(_record, _field), do: 0

  @spec cost_to_green([LogRecord.t()]) :: float() | nil
  defp cost_to_green([]), do: nil

  defp cost_to_green(passes) do
    mean(Enum.map(passes, &token_field(&1, :total)), length(passes))
  end

  # A zero denominator means every run for this agent was reviewer-flaked — no
  # attributable run to rate, so report 0.0 (the `reviewer_flaked` count, equal
  # to run_count here, is what disambiguates "no signal" from "genuinely 0%").
  @spec rate(non_neg_integer(), non_neg_integer()) :: float()
  defp rate(_count, 0), do: 0.0
  defp rate(count, total) when total > 0, do: count / total

  @spec mean([number()], pos_integer()) :: float()
  defp mean(values, count) when count > 0, do: Enum.sum(values) / count

  @doc false
  @spec duration_summary([non_neg_integer()]) :: duration_summary()
  def duration_summary(durations) when is_list(durations) do
    sorted = Enum.sort(durations)
    %{median: median(sorted), p90: percentile(sorted, 90)}
  end

  @spec median([non_neg_integer()]) :: number()
  defp median(sorted) do
    n = length(sorted)
    mid = div(n, 2)

    case rem(n, 2) do
      1 -> Enum.at(sorted, mid)
      0 -> (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  # Nearest-rank percentile via integer arithmetic so float drift never bumps the
  # rank past an element boundary (e.g. 0.9 * 10 rounding up to 10).
  @spec percentile([non_neg_integer()], pos_integer()) :: non_neg_integer()
  defp percentile(sorted, p) do
    n = length(sorted)
    rank = div(p * n + 99, 100)
    Enum.at(sorted, max(rank, 1) - 1)
  end
end
