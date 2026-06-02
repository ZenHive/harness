defmodule Harness.Cron.CapabilityBenchmarkScheduler do
  @moduledoc """
  Cron-driven worker that re-benchmarks stale and unmeasured capability cells.

  Each tick selects `(agent, domain)` cells flagged by
  `Harness.CapabilityScore.rebenchmark_candidates/1`, skips fresh cells and
  unavailable agents, runs the embedded benchmark corpus through
  `Harness.Batch.AgentEvaluation`, and persists scores via
  `Harness.CapabilityScore.score_domain/4`.

  Gated by `:cron_capability_benchmark` (`enabled` defaults to `false` in
  test). The Oban cron entry is registered unconditionally (Task 109) so a
  runtime flip takes effect on the next tick without a restart.
  """

  use Oban.Worker, queue: :cron, max_attempts: 1

  alias Harness.AgentRegistry
  alias Harness.Batch.AgentEvaluation
  alias Harness.Benchmark
  alias Harness.Benchmark.Corpus
  alias Harness.Benchmark.Item
  alias Harness.CapabilityScore
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Oban.Plugins.Cron

  require Logger

  @default_schedule "0 3 * * *"
  @cron_queue :cron
  @default_max_cells_per_tick 3
  @default_max_concurrency 1

  @type cron_status ::
          :disabled
          | {:enabled, String.t(), DateTime.t() | :unknown}
          | {:invalid, String.t(), term()}

  @type skip :: %{
          agent: atom(),
          domain: atom(),
          reason: :agent_unavailable | :cap_truncated | :project_lookup_failed | :compare_failed
        }

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    if enabled?() do
      tick =
        case Application.get_env(:harness, :capability_benchmark_plan) do
          fun when is_function(fun, 0) -> fun.()
          _ -> plan_tick(tick_opts())
        end

      Logger.info(
        "harness capability benchmark cron: schedule=#{schedule()} " <>
          "selected=#{length(tick.benchmark)} skipped=#{length(tick.skipped)} " <>
          "cells=#{inspect(cell_summaries(tick.benchmark))}"
      )

      Enum.each(tick.skipped, &log_skip/1)
      run_benchmarks(tick)
    end

    :ok
  end

  @doc "Returns whether autonomous capability benchmarking is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    config()
    |> Keyword.get(:enabled, false)
    |> Kernel.==(true)
  end

  @doc "Returns the configured cron expression for capability benchmarking."
  @spec schedule() :: String.t()
  def schedule do
    config()
    |> Keyword.get(:schedule, @default_schedule)
    |> to_string()
  end

  @doc false
  @spec cron_entry() :: {String.t(), module(), keyword()}
  def cron_entry do
    {schedule(), __MODULE__, [queue: @cron_queue, max_attempts: 1]}
  end

  @doc "Returns the next scheduled benchmark tick from `now`."
  @spec next_tick(DateTime.t()) :: {:ok, DateTime.t() | :unknown} | {:error, term()}
  def next_tick(now \\ DateTime.utc_now()) do
    if enabled?(), do: compute_next_tick(now), else: {:error, :disabled}
  end

  @spec compute_next_tick(DateTime.t()) :: {:ok, DateTime.t() | :unknown} | {:error, term()}
  defp compute_next_tick(now) do
    case Cron.parse(schedule()) do
      {:ok, expression} -> handle_next_at(next_at(expression, now))
      {:error, _} = err -> err
    end
  end

  # `Oban.Cron.Expression` is internal to Oban and exposes an opaque
  # `Oban.Plugins.Cron.expression()`; `apply/2` evades the opacity check
  # without faking knowledge dialyzer can't reach through.
  @spec next_at(term(), DateTime.t()) :: DateTime.t() | :unknown | term()
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp next_at(expression, now), do: apply(Oban.Cron.Expression, :next_at, [expression, now])

  @spec handle_next_at(DateTime.t() | :unknown | term()) ::
          {:ok, DateTime.t() | :unknown} | {:error, term()}
  defp handle_next_at(%DateTime{} = tick), do: {:ok, tick}
  defp handle_next_at(:unknown), do: {:ok, :unknown}
  defp handle_next_at(other), do: {:error, {:unexpected_next_tick, other}}

  @doc "Returns the human-facing capability-benchmark cron status."
  @spec status() :: cron_status()
  def status do
    case next_tick() do
      {:ok, tick} -> {:enabled, schedule(), tick}
      {:error, :disabled} -> :disabled
      {:error, reason} -> {:invalid, schedule(), reason}
    end
  end

  @doc """
  Plans one cron tick: which cells to benchmark and which to skip.

  Exposed for tests. Fresh cells never appear in `benchmark` or `skipped`
  (they are omitted entirely by `rebenchmark_candidates/1`).
  """
  @spec plan_tick(keyword()) :: %{
          corpus: [Item.t()],
          corpus_version: String.t(),
          score_opts: keyword(),
          benchmark: [map()],
          skipped: [skip()]
        }
  def plan_tick(opts \\ []) when is_list(opts) do
    corpus = corpus_items(opts)
    corpus_version = CapabilityScore.corpus_version(corpus)

    score_opts =
      opts
      |> Keyword.take([:agents, :domains, :reference_time, :freshness_window_days, :result_store])
      |> Keyword.put(:corpus_version, corpus_version)

    candidates =
      case CapabilityScore.rebenchmark_candidates(score_opts) do
        {:ok, list} -> prioritize(list)
        {:error, _reason} -> []
      end

    max_cells = Keyword.get(opts, :max_cells_per_tick, max_cells_per_tick())
    {selected, truncated} = Enum.split(candidates, max_cells)

    {benchmark, unavailable_skips} = build_benchmarks(selected, corpus, opts)

    truncated_skips =
      Enum.map(truncated, fn %{agent: agent, domain: domain} ->
        %{agent: agent, domain: domain, reason: :cap_truncated}
      end)

    %{
      corpus: corpus,
      corpus_version: corpus_version,
      score_opts: score_opts,
      benchmark: benchmark,
      skipped: truncated_skips ++ unavailable_skips
    }
  end

  @spec run_benchmarks(map()) :: :ok
  defp run_benchmarks(%{benchmark: []}), do: :ok

  defp run_benchmarks(tick) do
    Enum.each(tick.benchmark, fn work ->
      case benchmark_cell(work, tick) do
        :ok ->
          Logger.info(
            "harness capability benchmark cron: benchmarked #{work.agent}/#{work.domain} " <>
              "items=#{length(work.items)}"
          )

        {:error, reason} ->
          Logger.warning("harness capability benchmark cron: #{work.agent}/#{work.domain} failed: #{inspect(reason)}")
      end
    end)
  end

  @spec benchmark_cell(map(), map()) :: :ok | {:error, term()}
  defp benchmark_cell(%{agent: agent, domain: domain, adapter: adapter, items: items, project: project}, tick) do
    comparisons =
      Enum.map(items, fn %Item{} = bench_item ->
        roadmap_item = Benchmark.as_roadmap_item(bench_item, agent)

        case compare(roadmap_item, project, [adapter], compare_opts(tick)) do
          {:ok, comparison} -> {:ok, comparison}
          {:error, reason} -> {:error, {:compare_failed, bench_item.id, reason}}
        end
      end)

    with :ok <- collect_comparisons(comparisons),
         comparisons = Enum.map(comparisons, fn {:ok, c} -> c end),
         {:ok, _scores} <-
           CapabilityScore.score_domain(comparisons, tick.corpus, domain, tick.score_opts) do
      :ok
    end
  end

  @spec collect_comparisons([{:ok, term()} | {:error, term()}]) :: :ok | {:error, term()}
  defp collect_comparisons(comparisons) do
    case Enum.find(comparisons, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> :ok
    end
  end

  @spec build_benchmarks([map()], [Item.t()], keyword()) :: {[map()], [skip()]}
  defp build_benchmarks(candidates, corpus, opts) do
    candidates
    |> Enum.map_reduce([], fn %{agent: agent, domain: domain} = cell, skips ->
      with {:ok, adapter} <- AgentRegistry.delegatable_module_for_agent(agent),
           {:ok, adapter} <- AgentRegistry.select(adapter),
           items = Corpus.filter_by_domain(corpus, domain),
           false <- items == [],
           {:ok, project} <- lookup_project(items, opts) do
        work = %{
          agent: agent,
          domain: domain,
          adapter: adapter,
          items: items,
          project: project,
          cell_reason: cell.reason
        }

        {work, skips}
      else
        {:error, {:unsupported_agent, _}} ->
          {nil, [%{agent: agent, domain: domain, reason: :agent_unavailable} | skips]}

        {:error, {:non_delegatable, _}} ->
          {nil, [%{agent: agent, domain: domain, reason: :agent_unavailable} | skips]}

        {:error, {:no_available_agent, _}} ->
          {nil, [%{agent: agent, domain: domain, reason: :agent_unavailable} | skips]}

        {:error, {:unknown_project, name}} ->
          {nil, [%{agent: agent, domain: domain, reason: :project_lookup_failed, detail: name} | skips]}

        true ->
          {nil, skips}
      end
    end)
    |> then(fn {works, skips} -> {Enum.reject(works, &is_nil/1), skips} end)
  end

  @spec lookup_project([Item.t()], keyword()) :: {:ok, term()} | {:error, {:unknown_project, String.t()}}
  defp lookup_project(items, opts) do
    name = items |> hd() |> Map.fetch!(:target_project)

    case Keyword.get(opts, :project_lookup, &ProjectRegistry.lookup/1).(name) do
      {:ok, project} -> {:ok, project}
      {:error, _} = err -> err
    end
  end

  @spec prioritize([map()]) :: [map()]
  defp prioritize(candidates) do
    Enum.sort_by(candidates, fn
      %{reason: :unmeasured, agent: agent, domain: domain} -> {0, agent, domain}
      %{reason: :stale, agent: agent, domain: domain} -> {1, agent, domain}
      %{agent: agent, domain: domain} -> {2, agent, domain}
    end)
  end

  @spec compare(term(), term(), [module()], keyword()) ::
          {:ok, AgentEvaluation.Comparison.t()} | {:error, term()}
  defp compare(item, project, adapters, opts) do
    case Application.get_env(:harness, :capability_benchmark_compare) do
      fun when is_function(fun, 4) -> fun.(item, project, adapters, opts)
      _ -> AgentEvaluation.compare(item, project, adapters, opts)
    end
  end

  @spec corpus_items(keyword()) :: [Item.t()]
  defp corpus_items(opts) do
    cond do
      items = Keyword.get(opts, :corpus) -> items
      items = Application.get_env(:harness, :capability_benchmark_corpus) -> items
      true -> Corpus.list()
    end
  end

  @spec compare_opts(map()) :: keyword()
  defp compare_opts(tick) do
    [
      max_concurrency: max_concurrency(),
      result_store: Keyword.get(tick.score_opts, :result_store, ResultStore.configured())
    ]
  end

  @spec tick_opts() :: keyword()
  defp tick_opts do
    [
      max_cells_per_tick: max_cells_per_tick(),
      result_store: ResultStore.configured(),
      reference_time: DateTime.utc_now()
    ]
  end

  @spec cell_summaries([map()]) :: [{atom(), atom()}]
  defp cell_summaries(benchmark) do
    Enum.map(benchmark, fn %{agent: agent, domain: domain} -> {agent, domain} end)
  end

  @spec log_skip(skip() | map()) :: :ok
  defp log_skip(%{reason: :cap_truncated} = skip) do
    Logger.info("harness capability benchmark cron: deferred #{skip.agent}/#{skip.domain}: tick cell cap")
  end

  defp log_skip(%{reason: :agent_unavailable} = skip) do
    Logger.info("harness capability benchmark cron: skipped #{skip.agent}/#{skip.domain}: agent unavailable")
  end

  defp log_skip(%{reason: :project_lookup_failed} = skip) do
    Logger.info(
      "harness capability benchmark cron: skipped #{skip.agent}/#{skip.domain}: project #{inspect(skip[:detail])} not registered"
    )
  end

  defp log_skip(skip) do
    Logger.info("harness capability benchmark cron: skipped #{skip.agent}/#{skip.domain}: #{inspect(skip.reason)}")
  end

  @spec max_cells_per_tick() :: pos_integer()
  defp max_cells_per_tick do
    config()
    |> Keyword.get(:max_cells_per_tick, @default_max_cells_per_tick)
    |> max(1)
  end

  @spec max_concurrency() :: pos_integer()
  defp max_concurrency do
    config()
    |> Keyword.get(:max_concurrency, @default_max_concurrency)
    |> max(1)
  end

  @spec config() :: keyword()
  defp config, do: Application.get_env(:harness, :cron_capability_benchmark, [])
end
