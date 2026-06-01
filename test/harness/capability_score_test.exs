defmodule Harness.CapabilityScoreTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.Benchmark.Item
  alias Harness.CapabilityScore
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Harness.Run.Result, as: RunResult
  alias Harness.TokenUsage

  @scored_at ~U[2026-06-01 12:00:00Z]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "harness_capability_score_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store: {FileStore, root: root}}
  end

  test "scores a domain from seeded AgentEvaluation comparisons", %{store: store} do
    comparisons = [
      comparison("bench.otp.latch", [
        entry(Codex, "codex-1", :pass, repair_attempts: 0, token_usage: tokens(100, 20)),
        entry(Claude, "claude-1", :pass, repair_attempts: 1, token_usage: tokens(500, 100))
      ]),
      comparison("bench.otp.supervised_counter", [
        entry(Codex, "codex-2", :fail, repair_attempts: 2, first_attempt_failed_check_count: 3),
        entry(Claude, "claude-2", :pass, repair_attempts: 0, token_usage: tokens(300, 50))
      ])
    ]

    assert {:ok, scores} =
             CapabilityScore.score_domain(comparisons, corpus_items(), :otp,
               corpus_version: "otp-v1",
               scored_at: @scored_at,
               result_store: store
             )

    assert [:claude, :codex] = scores |> Enum.map(& &1.agent) |> Enum.sort()
    codex = Enum.find(scores, &(&1.agent == :codex))
    claude = Enum.find(scores, &(&1.agent == :claude))

    assert codex.domain == :otp
    assert codex.corpus_version == "otp-v1"
    assert codex.scored_at == @scored_at
    assert codex.run_count == 2
    assert codex.success_rate == 0.5
    assert codex.cost_to_green == 120.0
    assert codex.mean_repair_attempts == 1.0
    assert length(codex.raw_metrics) == 2

    assert claude.success_rate == 1.0
    assert claude.cost_to_green == 475.0
    assert claude.mean_repair_attempts == 0.5
    assert claude.composite_score > codex.composite_score

    assert {:ok, persisted} = ResultStore.get_capability_score(:codex, :otp, "otp-v1", store)
    assert persisted == codex
  end

  test "an unmeasured cell is explicit no data, distinct from a measured-low score", %{store: store} do
    assert :no_data = ResultStore.get_capability_score(:codex, :ecto, "ecto-v1", store)

    comparisons = [
      comparison("bench.ecto.embedded_profile", [
        entry(Codex, "codex-low", :fail, repair_attempts: 1, first_attempt_failed_check_count: 2)
      ])
    ]

    assert {:ok, [%CapabilityScore{} = low]} =
             CapabilityScore.score_domain(comparisons, corpus_items(), :ecto,
               corpus_version: "ecto-v1",
               scored_at: @scored_at,
               result_store: store
             )

    assert low.agent == :codex
    assert low.success_rate == 0.0
    assert low.composite_score > 0.0
    assert {:ok, ^low} = ResultStore.get_capability_score(:codex, :ecto, "ecto-v1", store)
  end

  test "recomputes the composite from retained raw metrics without new comparisons" do
    assert {:ok, [score]} =
             CapabilityScore.score_domain(
               [
                 comparison("bench.otp.latch", [
                   entry(Codex, "codex-1", :pass, repair_attempts: 0, token_usage: tokens(100, 25))
                 ]),
                 comparison("bench.otp.supervised_counter", [
                   entry(Codex, "codex-2", :pass, repair_attempts: 2, token_usage: tokens(200, 75))
                 ])
               ],
               corpus_items(),
               :otp,
               corpus_version: "otp-v1",
               scored_at: @scored_at,
               result_store: false
             )

    retuned = CapabilityScore.recompute(score)

    assert retuned.raw_metrics == score.raw_metrics
    assert retuned.success_rate == 1.0
    assert retuned.cost_to_green == 200.0
    assert retuned.mean_repair_attempts == 1.0
    assert retuned.composite_score == score.composite_score
  end

  defp comparison(task_id, entries) do
    %Comparison{
      batch_id: "batch-#{task_id}",
      task_id: task_id,
      total: length(entries),
      max_concurrency: length(entries),
      entries: entries
    }
  end

  defp entry(adapter, run_id, verdict, opts) do
    %Entry{
      adapter: adapter,
      run_id: run_id,
      state: if(verdict == :pass, do: :done, else: :failed),
      reason: if(verdict == :pass, do: :passed, else: :verification_red),
      verdict: verdict,
      repair_attempts: Keyword.fetch!(opts, :repair_attempts),
      duration_ms: Keyword.get(opts, :duration_ms, 100),
      first_attempt_failed_check_count: Keyword.get(opts, :first_attempt_failed_check_count, 0),
      agent_diff_size: nil,
      token_usage: Keyword.get(opts, :token_usage, TokenUsage.empty()),
      result: %RunResult{
        run_id: run_id,
        task_id: "task",
        state: if(verdict == :pass, do: :done, else: :failed),
        reason: if(verdict == :pass, do: :passed, else: :verification_red)
      }
    }
  end

  defp corpus_items do
    [
      item("bench.otp.latch", [:otp, :elixir]),
      item("bench.otp.supervised_counter", [:otp, :genserver]),
      item("bench.ecto.embedded_profile", [:ecto, :elixir])
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

  defp tokens(input, output), do: %TokenUsage{input: input, output: output, total: input + output}
end
