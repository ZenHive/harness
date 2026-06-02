defmodule Harness.Cron.CapabilityBenchmarkSchedulerTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentRegistry
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.Benchmark.Item
  alias Harness.CapabilityScore
  alias Harness.Cron.CapabilityBenchmarkScheduler
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Oban.Plugins.Cron

  @reference_time ~U[2026-06-01 12:00:00Z]

  setup do
    prior = Application.get_env(:harness, :cron_capability_benchmark)
    prior_compare = Application.get_env(:harness, :capability_benchmark_compare)

    root =
      Path.join(
        System.tmp_dir!(),
        "harness_capability_benchmark_cron_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env(:cron_capability_benchmark, prior)
      restore_env(:capability_benchmark_compare, prior_compare)
      Application.delete_env(:harness, :capability_benchmark_compare)
      Application.delete_env(:harness, :capability_benchmark_plan)
      File.rm_rf!(root)
    end)

    AgentRegistry.reset()
    ProjectRegistry.reset()

    project = ProjectFixture.from_repo("/tmp/harness-benchmark-plan", name: "harness")
    assert :ok = ProjectRegistry.register(project)

    {:ok, store: {FileStore, root: root}, project: project}
  end

  test "disabled by default but the cron plugin registers the benchmark entry" do
    refute CapabilityBenchmarkScheduler.enabled?()

    crontab = cron_crontab()
    assert CapabilityBenchmarkScheduler.cron_entry() in crontab
  end

  test "plan_tick selects stale and unmeasured cells and skips fresh cells", %{store: store, project: project} do
    fresh = score(:codex, :otp, ~U[2026-05-20 00:00:00Z], 700.0)
    stale = score(:claude, :otp, ~U[2026-04-20 00:00:00Z], 900.0)

    assert :ok = ResultStore.save_capability_score(fresh, store)
    assert :ok = ResultStore.save_capability_score(stale, store)

    tick =
      plan(
        store: store,
        project: project,
        agents: [:codex, :claude, :cursor],
        domains: [:otp],
        corpus: corpus_items()
      )

    assert Enum.map(tick.benchmark, &{&1.agent, &1.domain}) == [{:cursor, :otp}, {:claude, :otp}]
    refute Enum.any?(tick.benchmark, &(&1.agent == :codex))
    assert tick.skipped == []
  end

  test "plan_tick defers cells beyond max_cells_per_tick with an explicit skip log reason", %{
    store: store,
    project: project
  } do
    for agent <- [:claude, :codex, :cursor] do
      assert :ok = ResultStore.save_capability_score(score(agent, :otp, ~U[2026-04-01 00:00:00Z], 100.0), store)
    end

    tick =
      plan(
        store: store,
        project: project,
        agents: [:claude, :codex, :cursor],
        domains: [:otp],
        corpus: corpus_items(),
        max_cells_per_tick: 1
      )

    assert length(tick.benchmark) == 1
    assert Enum.count(tick.skipped, &(&1.reason == :cap_truncated)) == 2
  end

  test "plan_tick skips unavailable agents without silently dropping the cell", %{store: store, project: project} do
    assert :ok = ResultStore.save_capability_score(score(:codex, :otp, ~U[2026-05-20 00:00:00Z], 700.0), store)
    assert :ok = AgentRegistry.mark_unavailable(Claude, :quota)

    tick =
      plan(
        store: store,
        agents: [:claude, :codex],
        domains: [:otp],
        corpus: corpus_items(),
        project: project
      )

    assert tick.benchmark == []
    assert [%{agent: :claude, domain: :otp, reason: :agent_unavailable}] = tick.skipped
  end

  test "enabled tick persists a score after a mocked compare run", %{store: store, project: project} do
    Application.put_env(:harness, :cron_capability_benchmark, enabled: true, schedule: "* * * * *")

    Application.put_env(:harness, :capability_benchmark_compare, fn item, _project, [adapter], _opts ->
      {:ok,
       %Comparison{
         batch_id: "bench-batch",
         task_id: item.id,
         total: 1,
         max_concurrency: 1,
         entries: [
           %Entry{
             adapter: adapter,
             run_id: "run-#{item.id}",
             state: :done,
             reason: :passed,
             verdict: :pass,
             repair_attempts: 0,
             first_attempt_failed_check_count: 0,
             result: %Harness.Run.Result{run_id: "run-#{item.id}", task_id: item.id, state: :done, reason: :passed}
           }
         ]
       }}
    end)

    tick = plan(store: store, project: project, agents: [:codex], domains: [:otp], corpus: corpus_items())

    assert [%{agent: :codex, domain: :otp}] = Enum.map(tick.benchmark, &Map.take(&1, [:agent, :domain]))

    Application.put_env(:harness, :capability_benchmark_plan, fn -> tick end)

    assert :ok = CapabilityBenchmarkScheduler.perform(%Oban.Job{})

    assert {:ok, score} = ResultStore.get_capability_score(:codex, :otp, tick.corpus_version, store)
    assert score.run_count == 2
    assert score.composite_score > 0
  end

  defp plan(opts) do
    project = Keyword.fetch!(opts, :project)

    opts =
      opts
      |> Keyword.put(:result_store, Keyword.get(opts, :store))
      |> Keyword.put(:project_lookup, fn "harness" -> {:ok, project} end)

    CapabilityBenchmarkScheduler.plan_tick(
      Keyword.merge(
        [
          reference_time: @reference_time,
          max_cells_per_tick: 3
        ],
        opts
      )
    )
  end

  defp cron_crontab do
    Harness.Oban.oban_opts()
    |> Keyword.get(:plugins, [])
    |> Enum.find_value([], fn
      {Cron, crontab: entries} -> entries
      _ -> false
    end)
  end

  defp corpus_items do
    [
      item("bench.otp.latch", [:otp, :elixir]),
      item("bench.otp.supervised_counter", [:otp, :genserver])
    ]
  end

  defp item(id, domains) do
    {:ok, item} =
      Item.build(
        id: id,
        version: 1,
        domains: domains,
        intent: "implement #{id}",
        acceptance_criteria: ["it works"],
        target_project: "harness",
        check_stack: "elixir",
        expected_green: true
      )

    item
  end

  defp score(agent, domain, scored_at, composite_score) do
    %CapabilityScore{
      agent: agent,
      domain: domain,
      corpus_version: CapabilityScore.corpus_version(corpus_items()),
      scored_at: scored_at,
      run_count: 1,
      success_rate: composite_score / 1_000,
      cost_to_green: 100.0,
      mean_repair_attempts: 0.0,
      mean_first_attempt_failed_check_count: 0.0,
      composite_score: composite_score,
      raw_metrics: []
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
