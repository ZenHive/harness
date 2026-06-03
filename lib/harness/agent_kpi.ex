defmodule Harness.AgentKPI do
  @moduledoc """
  Per-agent KPI rollup over the run records `Harness.ResultStore` already persists.

  This context adds **no new capture** — every input field (`agent`, `verdict`,
  `duration_ms`, `token_usage`, `review_iterations`, `review_ratings`,
  `reviewer_adapter`, `domains`) is already on `Harness.Run.LogRecord`. It is a
  read-only aggregation that makes the data we already have viewable at a
  glance: roll a record list up by `agent` into success rate,
  first-attempt-pass rate, duration median/p90, mean tokens, mean review
  iterations, the reviewer's mean ratings, and a cost-to-green composite.
  `aggregate_by_agent_domain/1` adds the same rollup keyed by `{agent, domain}`
  for per-domain slicing.

  ## Reviewer-as-gate rollup

  `aggregate_reviewer_rejections/1` is the mirror-image view: keyed by
  `reviewer_adapter` (the cross-family reviewer that gated the run), it reports
  each reviewer's rejection rate. Since rejection is near-never by design, a
  reviewer with an outlier rejection rate is the signal — it lets cross-family
  selection deprioritize a reviewer that rejects too freely.

  ## Pure by construction

  `aggregate/1` does no I/O — the caller supplies the record set (typically from
  `Harness.ResultStore.list_run_records/1`), so the rollup is testable without a
  store. Aggregates are recomputed on read, never persisted.

  ## Conventions

    * A `verdict` of `:approve` (the reviewer AI's decision) is a success;
      `:reject` and `nil` (the run never reached review) both count as
      non-successes in the denominators.
    * Token means treat an unreported (`nil`) component as `0` and divide by the
      agent's full run count. In practice reporting is all-or-nothing per agent
      (a plain-text adapter reports none), so this matches the per-agent rollup.
    * `cost_to_green` is the mean total tokens across an agent's `:approve` runs;
      an agent with zero `:approve` runs reports `nil` (no divide-by-zero, not `0`).
  """

  alias Harness.CapabilityDomain
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  @typedoc "Median and 90th-percentile (nearest-rank) of an agent's run durations."
  @type duration_summary :: %{median: number(), p90: non_neg_integer()}

  @typedoc "Mean tokens per run for an agent, by component."
  @type token_means :: %{input: float(), output: float(), total: float()}

  @typedoc "Mean of each reviewer rating key (the keys are the reviewer's, free-form)."
  @type rating_means :: %{optional(String.t()) => float()}

  @typedoc "Rolled-up KPIs for one agent."
  @type agent_kpi :: %{
          run_count: pos_integer(),
          success_rate: float(),
          first_attempt_pass_rate: float(),
          duration_ms: duration_summary(),
          tokens: token_means(),
          review_iterations: float(),
          ratings: rating_means(),
          cost_to_green: float() | nil
        }

  @typedoc "Rejection metrics for one reviewer adapter acting AS the gate."
  @type reviewer_rejection :: %{
          reviewed_count: pos_integer(),
          rejection_count: non_neg_integer(),
          rejection_rate: float()
        }

  @typedoc "Per-reviewer-adapter rejection ledger keyed by the reviewer module."
  @type reviewer_ledger :: %{optional(module()) => reviewer_rejection()}

  @typedoc "Per-agent ledger keyed by the record's `agent` atom (or `nil` for an unregistered adapter)."
  @type t :: %{optional(atom() | nil) => agent_kpi()}

  @typedoc "Per-(agent, domain) ledger keyed by `{agent, domain}`."
  @type by_agent_domain :: %{optional({atom() | nil, CapabilityDomain.bucket()}) => agent_kpi()}

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
    passes = Enum.filter(records, &(&1.verdict == :approve))
    durations = records |> Enum.map(& &1.duration_ms) |> Enum.sort()

    %{
      run_count: run_count,
      success_rate: rate(length(passes), run_count),
      first_attempt_pass_rate: rate(first_attempt_passes(records), run_count),
      duration_ms: %{median: median(durations), p90: percentile(durations, 90)},
      tokens: token_means(records, run_count),
      review_iterations: mean(Enum.map(records, & &1.review_iterations), run_count),
      ratings: rating_means(Enum.map(records, &record_ratings/1)),
      cost_to_green: cost_to_green(passes)
    }
  end

  @doc """
  Rolls records up by `reviewer_adapter` into a per-reviewer rejection ledger.

  Only records the reviewer actually gated count toward the denominator —
  `reviewer_adapter` set and a non-nil `verdict`. A reviewer's `rejection_rate`
  is its `:reject` verdicts over those gated runs; an empty input returns `%{}`.
  """
  @spec aggregate_reviewer_rejections([LogRecord.t()]) :: reviewer_ledger()
  def aggregate_reviewer_rejections(records) when is_list(records) do
    records
    |> Enum.filter(&reviewed?/1)
    |> Enum.group_by(&reviewer_adapter/1)
    |> Map.new(fn {reviewer, group} -> {reviewer, summarize_reviewer(group)} end)
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

  # Tolerates a pre-rating persisted record whose term predates the field.
  @spec record_ratings(LogRecord.t()) :: map()
  defp record_ratings(record), do: Map.get(record, :review_ratings) || %{}

  @spec reviewed?(LogRecord.t()) :: boolean()
  defp reviewed?(record) do
    not is_nil(reviewer_adapter(record)) and record_verdict(record) in [:approve, :reject]
  end

  @spec reviewer_adapter(LogRecord.t()) :: module() | nil
  defp reviewer_adapter(record), do: Map.get(record, :reviewer_adapter)

  @spec record_verdict(LogRecord.t()) :: atom() | nil
  defp record_verdict(record), do: Map.get(record, :verdict)

  @spec summarize_reviewer([LogRecord.t()]) :: reviewer_rejection()
  defp summarize_reviewer(records) do
    reviewed_count = length(records)
    rejection_count = Enum.count(records, &(record_verdict(&1) == :reject))

    %{
      reviewed_count: reviewed_count,
      rejection_count: rejection_count,
      rejection_rate: rejection_count / reviewed_count
    }
  end

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

  @spec rate(non_neg_integer(), pos_integer()) :: float()
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
