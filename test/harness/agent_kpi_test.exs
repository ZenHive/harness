defmodule Harness.AgentKPITest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentKPI
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  # Builds a LogRecord with KPI-relevant fields overridable; the rest are inert
  # defaults that satisfy @enforce_keys without affecting aggregation.
  defp record(fields) do
    base = %{
      batch_id: "batch-1",
      run_id: "run-1",
      task_id: "t",
      adapter: Claude,
      state: :done,
      reason: :approved,
      duration_ms: 100,
      review_iterations: 0,
      token_usage: TokenUsage.empty()
    }

    struct!(LogRecord, Map.merge(base, Map.new(fields)))
  end

  describe "aggregate/1 boundaries" do
    test "empty input returns an empty map" do
      assert AgentKPI.aggregate([]) == %{}
    end

    test "an agent with zero approved runs reports cost_to_green nil, not 0" do
      records = [
        record(agent: :codex, verdict: :reject),
        record(agent: :codex, verdict: nil)
      ]

      kpi = AgentKPI.aggregate(records)

      assert kpi[:codex].run_count == 2
      assert kpi[:codex].success_rate == 0.0
      assert kpi[:codex].first_attempt_pass_rate == 0.0
      assert kpi[:codex].cost_to_green == nil
    end

    test "an approved agent that reported no tokens distinguishes 0.0 from nil cost_to_green" do
      records = [record(agent: :antigravity, verdict: :approve, token_usage: TokenUsage.empty())]

      kpi = AgentKPI.aggregate(records)

      assert kpi[:antigravity].tokens == %{input: 0.0, output: 0.0, total: 0.0}
      assert kpi[:antigravity].cost_to_green == 0.0
    end

    test "a record with a nil token_usage (e.g. a pre-token persisted record) contributes 0 tokens" do
      records = [
        record(agent: :claude, verdict: :approve, token_usage: nil),
        record(agent: :claude, verdict: :approve, token_usage: tokens(100, 100))
      ]

      kpi = AgentKPI.aggregate(records)

      assert kpi[:claude].tokens == %{input: 50.0, output: 50.0, total: 100.0}
      assert kpi[:claude].cost_to_green == 100.0
    end
  end

  describe "aggregate/1 single agent" do
    test "rolls success, first-attempt, duration, token, reviewer-fix, and cost-to-green metrics" do
      records = [
        record(
          agent: :claude,
          verdict: :approve,
          review_iterations: 0,
          duration_ms: 100,
          token_usage: tokens(600, 400)
        ),
        record(
          agent: :claude,
          verdict: :approve,
          review_iterations: 1,
          duration_ms: 200,
          token_usage: tokens(1200, 800)
        ),
        record(
          agent: :claude,
          verdict: :reject,
          review_iterations: 1,
          duration_ms: 300,
          token_usage: tokens(1800, 1200)
        ),
        record(
          agent: :claude,
          verdict: :approve,
          review_iterations: 0,
          duration_ms: 400,
          token_usage: tokens(2400, 1600)
        )
      ]

      kpi = AgentKPI.aggregate(records)[:claude]

      assert kpi.run_count == 4
      assert kpi.success_rate == 0.75
      assert kpi.first_attempt_pass_rate == 0.5
      assert kpi.duration_ms == %{median: 250.0, p90: 400}
      assert kpi.tokens == %{input: 1500.0, output: 1000.0, total: 2500.0}
      assert kpi.review_iterations == 0.5
      # mean total tokens across the 3 approved runs (1000 + 2000 + 4000) / 3
      assert kpi.cost_to_green == 7000 / 3
    end

    test "median of an odd run count is the middle duration" do
      records = [
        record(agent: :claude, duration_ms: 100),
        record(agent: :claude, duration_ms: 300),
        record(agent: :claude, duration_ms: 200)
      ]

      assert AgentKPI.aggregate(records)[:claude].duration_ms.median == 200
    end
  end

  describe "aggregate/1 multiple agents" do
    test "keys the ledger by agent and isolates each agent's records" do
      records = [
        record(agent: :claude, verdict: :approve, duration_ms: 100, token_usage: tokens(100, 100)),
        record(agent: :claude, verdict: :reject, duration_ms: 300, token_usage: tokens(300, 300)),
        record(agent: :codex, verdict: :approve, duration_ms: 50, token_usage: tokens(10, 10))
      ]

      kpi = AgentKPI.aggregate(records)

      assert kpi |> Map.keys() |> Enum.sort() == [:claude, :codex]
      assert kpi[:claude].run_count == 2
      assert kpi[:claude].success_rate == 0.5
      assert kpi[:codex].run_count == 1
      assert kpi[:codex].success_rate == 1.0
      assert kpi[:codex].cost_to_green == 20.0
    end

    test "all-rejected agent reports success_rate 0.0 and cost_to_green nil alongside a healthy agent" do
      records = [
        record(agent: :claude, verdict: :approve, token_usage: tokens(500, 500)),
        record(agent: :grok, verdict: :reject),
        record(agent: :grok, verdict: :reject)
      ]

      kpi = AgentKPI.aggregate(records)

      assert kpi[:claude].success_rate == 1.0
      assert kpi[:claude].cost_to_green == 1000.0
      assert kpi[:grok].success_rate == 0.0
      assert kpi[:grok].cost_to_green == nil
    end
  end

  describe "aggregate_by_agent_domain/1" do
    test "groups by {agent, domain} and buckets untagged records under :untagged" do
      records = [
        record(agent: :claude, verdict: :approve, domains: [:otp]),
        record(agent: :claude, verdict: :reject, domains: [:liveview]),
        record(agent: :codex, verdict: :approve),
        record(agent: :codex, verdict: :approve, domains: [:otp, :ecto])
      ]

      kpi = AgentKPI.aggregate_by_agent_domain(records)

      assert kpi[{:claude, :otp}].run_count == 1
      assert kpi[{:claude, :otp}].success_rate == 1.0
      assert kpi[{:claude, :liveview}].run_count == 1
      assert kpi[{:claude, :liveview}].success_rate == 0.0
      assert kpi[{:codex, :untagged}].run_count == 1
      assert kpi[{:codex, :otp}].run_count == 1
      assert kpi[{:codex, :ecto}].run_count == 1
    end

    test "treats missing domains on legacy records as untagged without crashing" do
      legacy =
        struct!(LogRecord, %{
          batch_id: "batch-1",
          run_id: "run-legacy",
          task_id: "t",
          adapter: Claude,
          state: :done,
          reason: :approved,
          duration_ms: 100,
          review_iterations: 0,
          agent: :claude,
          verdict: :approve,
          token_usage: TokenUsage.empty()
        })

      kpi = AgentKPI.aggregate_by_agent_domain([legacy])

      assert kpi[{:claude, :untagged}].run_count == 1
    end
  end

  describe "aggregate/1 reviewer ratings" do
    test "means each numeric rating key per agent over the records that report it" do
      records = [
        record(agent: :claude, verdict: :approve, review_ratings: %{"performance" => 8, "idiom" => 6}),
        record(agent: :claude, verdict: :approve, review_ratings: %{"performance" => 6, "idiom" => 10}),
        # A record that never reached review contributes no ratings — absent keys
        # are not counted as 0.
        record(agent: :claude, verdict: nil, review_ratings: %{})
      ]

      ratings = AgentKPI.aggregate(records)[:claude].ratings

      assert ratings == %{"performance" => 7.0, "idiom" => 8.0}
    end

    test "ignores non-numeric rating values and absent keys, never coercing to 0" do
      records = [
        record(agent: :codex, verdict: :approve, review_ratings: %{"performance" => 9, "notes" => "great"}),
        record(agent: :codex, verdict: :approve, review_ratings: %{"performance" => 7})
      ]

      ratings = AgentKPI.aggregate(records)[:codex].ratings

      # "notes" (string) is dropped; "performance" means the two numbers it has.
      assert ratings == %{"performance" => 8.0}
    end

    test "an agent with no ratings reports an empty map, not a crash" do
      assert AgentKPI.aggregate([record(agent: :grok, verdict: :approve)])[:grok].ratings == %{}
    end
  end

  describe "aggregate_reviewer_rejections/1" do
    test "rejection rate is keyed by reviewer_adapter over gated runs only" do
      records = [
        # Claude reviewed 4 runs, rejecting 1.
        record(reviewer_adapter: ClaudeReviewer, verdict: :approve),
        record(reviewer_adapter: ClaudeReviewer, verdict: :approve),
        record(reviewer_adapter: ClaudeReviewer, verdict: :approve),
        record(reviewer_adapter: ClaudeReviewer, verdict: :reject),
        # Codex reviewed 2, rejecting both.
        record(reviewer_adapter: CodexReviewer, verdict: :reject),
        record(reviewer_adapter: CodexReviewer, verdict: :reject),
        # A run that never reached a reviewer (no adapter, nil verdict) is not gated.
        record(reviewer_adapter: nil, verdict: nil)
      ]

      ledger = AgentKPI.aggregate_reviewer_rejections(records)

      assert ledger[ClaudeReviewer] == %{reviewed_count: 4, rejection_count: 1, rejection_rate: 0.25}
      assert ledger[CodexReviewer] == %{reviewed_count: 2, rejection_count: 2, rejection_rate: 1.0}
      refute Map.has_key?(ledger, nil)
    end

    test "empty input returns an empty ledger" do
      assert AgentKPI.aggregate_reviewer_rejections([]) == %{}
    end

    test "rating_means/1 is reusable over a bare list of ratings maps" do
      assert AgentKPI.rating_means([%{"a" => 2}, %{"a" => 4, "b" => 10}]) == %{"a" => 3.0, "b" => 10.0}
      assert AgentKPI.rating_means([]) == %{}
    end
  end

  describe "aggregate/1 reviewer-fixed vs first-try" do
    test "first_attempt_pass_rate separates a first-try agent from one whose reviewer always fixes" do
      records = [
        record(agent: :first_try, verdict: :approve, review_iterations: 0),
        record(agent: :first_try, verdict: :approve, review_iterations: 0),
        record(agent: :needs_fixes, verdict: :approve, review_iterations: 1),
        record(agent: :needs_fixes, verdict: :approve, review_iterations: 1)
      ]

      kpi = AgentKPI.aggregate(records)

      # Both agents land approved every time...
      assert kpi[:first_try].success_rate == 1.0
      assert kpi[:needs_fixes].success_rate == 1.0
      # ...but only the first-try agent passes without reviewer fixes.
      assert kpi[:first_try].first_attempt_pass_rate == 1.0
      assert kpi[:first_try].review_iterations == 0.0
      assert kpi[:needs_fixes].first_attempt_pass_rate == 0.0
      assert kpi[:needs_fixes].review_iterations == 1.0
    end
  end

  defp tokens(input, output) do
    %TokenUsage{input: input, output: output, total: input + output}
  end
end
