defmodule Harness.CapabilityScoreTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.CapabilityScore
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Harness.Run.Result, as: RunResult
  alias Harness.TokenUsage

  @scored_at ~U[2026-06-01 12:00:00Z]
  @reference_time ~U[2026-06-01 12:00:00Z]

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
        entry(Codex, "codex-1", :approve, reviewer_diff_size: 0, token_usage: tokens(100, 20)),
        entry(Claude, "claude-1", :approve, reviewer_diff_size: 10, token_usage: tokens(500, 100))
      ]),
      comparison("bench.otp.supervised_counter", [
        entry(Codex, "codex-2", :reject, reviewer_diff_size: 40),
        entry(Claude, "claude-2", :approve, reviewer_diff_size: 0, token_usage: tokens(300, 50))
      ])
    ]

    assert {:ok, scores} =
             CapabilityScore.score_domain(comparisons, :otp,
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
    assert codex.mean_reviewer_diff_size == 20.0
    assert length(codex.raw_metrics) == 2

    assert claude.success_rate == 1.0
    assert claude.cost_to_green == 475.0
    assert claude.mean_reviewer_diff_size == 5.0
    assert claude.composite_score > codex.composite_score

    assert {:ok, persisted} = ResultStore.get_capability_score(:codex, :otp, "otp-v1", store)
    assert persisted == codex
  end

  test "means the reviewer ratings per agent and lets them break a same-success tie", %{store: store} do
    # Both agents pass every run with identical cost and zero reviewer fixes, so
    # success_rate and the cost/fix tiebreakers are equal — only the reviewer's
    # ratings can separate them.
    comparisons = [
      comparison("bench.otp.latch", [
        entry(Codex, "codex-1", :approve,
          reviewer_diff_size: 0,
          token_usage: tokens(100, 0),
          ratings: %{"performance" => 9, "idiom" => 9}
        ),
        entry(Claude, "claude-1", :approve,
          reviewer_diff_size: 0,
          token_usage: tokens(100, 0),
          ratings: %{"performance" => 4, "idiom" => 4}
        )
      ])
    ]

    assert {:ok, scores} =
             CapabilityScore.score_domain(comparisons, :otp,
               corpus_version: "otp-v1",
               scored_at: @scored_at,
               result_store: store
             )

    codex = Enum.find(scores, &(&1.agent == :codex))
    claude = Enum.find(scores, &(&1.agent == :claude))

    assert codex.mean_ratings == %{"performance" => 9.0, "idiom" => 9.0}
    assert claude.mean_ratings == %{"performance" => 4.0, "idiom" => 4.0}

    # Equal success/cost/fix; the better-rated agent sorts higher purely on ratings.
    assert codex.success_rate == claude.success_rate
    assert codex.composite_score > claude.composite_score
  end

  test "derives a corpus_version fingerprint from the compared task ids when none is given" do
    assert {:ok, [score]} =
             CapabilityScore.score_domain(
               [
                 comparison("task.42", [
                   entry(Codex, "codex-1", :approve, reviewer_diff_size: 0, token_usage: tokens(100, 25))
                 ])
               ],
               :otp,
               scored_at: @scored_at,
               result_store: false
             )

    # The fingerprint is deterministic over the sorted unique task ids.
    assert is_binary(score.corpus_version)
    assert score.corpus_version != ""
  end

  test "an unmeasured cell is explicit no data, distinct from a measured-low score", %{store: store} do
    assert :no_data = ResultStore.get_capability_score(:codex, :ecto, "ecto-v1", store)

    comparisons = [
      comparison("bench.ecto.embedded_profile", [
        entry(Codex, "codex-low", :reject, reviewer_diff_size: 25)
      ])
    ]

    assert {:ok, [%CapabilityScore{} = low]} =
             CapabilityScore.score_domain(comparisons, :ecto,
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
                   entry(Codex, "codex-1", :approve, reviewer_diff_size: 0, token_usage: tokens(100, 25))
                 ]),
                 comparison("bench.otp.supervised_counter", [
                   entry(Codex, "codex-2", :approve, reviewer_diff_size: 30, token_usage: tokens(200, 75))
                 ])
               ],
               :otp,
               corpus_version: "otp-v1",
               scored_at: @scored_at,
               result_store: false
             )

    retuned = CapabilityScore.recompute(score)

    assert retuned.raw_metrics == score.raw_metrics
    assert retuned.success_rate == 1.0
    assert retuned.cost_to_green == 200.0
    assert retuned.mean_reviewer_diff_size == 15.0
    assert retuned.composite_score == score.composite_score
  end

  describe "freshness and re-benchmark candidates" do
    test "classifies scores as fresh or stale against an injected reference time" do
      fresh = score(:codex, :otp, ~U[2026-05-15 00:00:00Z], 100.0)
      stale = score(:claude, :otp, ~U[2026-04-30 00:00:00Z], 100.0)

      assert CapabilityScore.freshness(fresh, reference_time: @reference_time) == :fresh
      assert CapabilityScore.freshness(stale, reference_time: @reference_time) == :stale

      assert CapabilityScore.freshness(stale, reference_time: @reference_time, freshness_window_days: 45) ==
               :fresh

      assert CapabilityScore.discounted_composite_score(stale, reference_time: @reference_time) == 50.0
    end

    test "lists stale and unmeasured cells without deleting stale scores", %{store: store} do
      fresh = score(:codex, :otp, ~U[2026-05-20 00:00:00Z], 700.0)
      stale = score(:claude, :otp, ~U[2026-04-20 00:00:00Z], 900.0)

      assert :ok = ResultStore.save_capability_score(fresh, store)
      assert :ok = ResultStore.save_capability_score(stale, store)

      assert {:ok, candidates} =
               CapabilityScore.rebenchmark_candidates(
                 agents: [:codex, :claude, :cursor],
                 domains: [:otp],
                 reference_time: @reference_time,
                 result_store: store
               )

      assert Enum.map(candidates, &{&1.agent, &1.domain, &1.reason}) == [
               {:claude, :otp, :stale},
               {:cursor, :otp, :unmeasured}
             ]

      assert {:ok, ^stale} = ResultStore.get_capability_score(:claude, :otp, "test-v1", store)
    end
  end

  describe "recommend/2" do
    test "exploits the best measured fresh score", %{store: store} do
      assert :ok = ResultStore.save_capability_score(score(:codex, :otp, ~U[2026-05-30 00:00:00Z], 800.0), store)
      assert :ok = ResultStore.save_capability_score(score(:claude, :otp, ~U[2026-05-30 00:00:00Z], 700.0), store)

      assert {:ok, recommendation} =
               CapabilityScore.recommend(:otp,
                 agents: [:claude, :codex],
                 reference_time: @reference_time,
                 result_store: store
               )

      assert recommendation.agent == :codex
      assert recommendation.strategy == :exploit
      assert recommendation.rationale == :best_fresh_score
      assert Enum.map(recommendation.ranked, & &1.agent) == [:codex, :claude]
    end

    test "surfaces an unmeasured cell as an exploration candidate", %{store: store} do
      assert :ok = ResultStore.save_capability_score(score(:claude, :otp, ~U[2026-05-30 00:00:00Z], 700.0), store)

      assert {:ok, recommendation} =
               CapabilityScore.recommend(:otp,
                 agents: [:claude, :codex],
                 reference_time: @reference_time,
                 result_store: store
               )

      assert recommendation.agent == :codex
      assert recommendation.strategy == :explore
      assert recommendation.rationale == :unmeasured_cell
      assert [%{agent: :codex, measurement: :unmeasured} | _] = recommendation.ranked
    end

    test "discounts a stale best raw score before exploiting", %{store: store} do
      assert :ok = ResultStore.save_capability_score(score(:codex, :otp, ~U[2026-04-20 00:00:00Z], 1_000.0), store)
      assert :ok = ResultStore.save_capability_score(score(:claude, :otp, ~U[2026-05-30 00:00:00Z], 600.0), store)

      assert {:ok, recommendation} =
               CapabilityScore.recommend(:otp,
                 agents: [:claude, :codex],
                 reference_time: @reference_time,
                 result_store: store
               )

      assert recommendation.agent == :claude
      assert recommendation.strategy == :exploit

      assert [%{agent: :claude}, %{agent: :codex, freshness: :stale, effective_score: 500.0}] =
               recommendation.ranked
    end

    test "falls back when the domain has no measured scores at all", %{store: store} do
      assert {:ok, recommendation} =
               CapabilityScore.recommend(:otp,
                 agents: [:claude, :codex],
                 fallback_agent: :claude,
                 reference_time: @reference_time,
                 result_store: store
               )

      assert recommendation.agent == :claude
      assert recommendation.strategy == :fallback_no_data
      assert Enum.all?(recommendation.ranked, &(&1.measurement == :unmeasured))
    end
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
    {state, reason} =
      if verdict == :approve do
        {:done, :approved}
      else
        {:failed, {:review_rejected, "rejected"}}
      end

    %Entry{
      adapter: adapter,
      run_id: run_id,
      state: state,
      reason: reason,
      verdict: verdict,
      reviewer_diff_size: Keyword.fetch!(opts, :reviewer_diff_size),
      duration_ms: Keyword.get(opts, :duration_ms, 100),
      agent_diff_size: nil,
      ratings: Keyword.get(opts, :ratings, %{}),
      token_usage: Keyword.get(opts, :token_usage, TokenUsage.empty()),
      result: %RunResult{
        run_id: run_id,
        task_id: "task",
        state: state,
        reason: reason
      }
    }
  end

  defp score(agent, domain, scored_at, composite_score) do
    %CapabilityScore{
      agent: agent,
      domain: domain,
      corpus_version: "test-v1",
      scored_at: scored_at,
      run_count: 1,
      success_rate: composite_score / 1_000,
      cost_to_green: 100.0,
      mean_reviewer_diff_size: 0.0,
      composite_score: composite_score,
      raw_metrics: []
    }
  end

  defp tokens(input, output), do: %TokenUsage{input: input, output: output, total: input + output}
end
