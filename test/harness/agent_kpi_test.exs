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
    test "uses current review_skills scores for per-agent quality means" do
      records = [
        record(
          agent: :claude,
          verdict: :approve,
          review_skills: %{
            "otp" => %{"score" => 8, "note" => "supervision was correct"},
            "truthfulness" => %{"score" => 9, "note" => "report matched diff"}
          }
        ),
        record(
          agent: :claude,
          verdict: :approve,
          review_skills: %{"otp" => %{"score" => 6, "note" => "minor callback issue"}}
        )
      ]

      ratings = AgentKPI.aggregate(records)[:claude].ratings

      assert ratings == %{"otp" => 7.0, "truthfulness" => 9.0}
    end

    test "prefers current review_skills over legacy review_ratings when both are present" do
      records = [
        record(
          agent: :codex,
          verdict: :approve,
          review_skills: %{"test_rigor" => %{"score" => 9, "note" => "covered edge cases"}},
          review_ratings: %{"performance" => 1}
        )
      ]

      ratings = AgentKPI.aggregate(records)[:codex].ratings

      assert ratings == %{"test_rigor" => 9.0}
    end

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

    test "empty current and legacy rating blocks contribute nothing without crashing" do
      records = [
        record(agent: :grok, verdict: :approve, review_skills: %{}, review_ratings: %{}),
        record(agent: :grok, verdict: :approve, review_skills: nil, review_ratings: nil)
      ]

      assert AgentKPI.aggregate(records)[:grok].ratings == %{}
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

      assert ledger[ClaudeReviewer] ==
               %{reviewed_count: 4, rejection_count: 1, rejection_rate: 0.25, no_verdict_count: 0, no_verdict_rate: 0.0}

      assert ledger[CodexReviewer] ==
               %{reviewed_count: 2, rejection_count: 2, rejection_rate: 1.0, no_verdict_count: 0, no_verdict_rate: 0.0}

      refute Map.has_key?(ledger, nil)
    end

    test "review_stuck runs count toward the reviewer's verdict-write reliability" do
      records = [
        # Cursor gated 4 runs: approved 2, but flaked (wrote no verdict) on 2.
        record(reviewer_adapter: CursorReviewer, verdict: :approve),
        record(reviewer_adapter: CursorReviewer, verdict: :approve),
        record(reviewer_adapter: CursorReviewer, verdict: nil, reason: {:review_stuck, "no artifact"}),
        record(reviewer_adapter: CursorReviewer, verdict: nil, reason: {:review_stuck, "no artifact"}),
        # Claude gated 1, wrote its verdict.
        record(reviewer_adapter: ClaudeReviewer, verdict: :approve)
      ]

      ledger = AgentKPI.aggregate_reviewer_rejections(records)

      assert ledger[CursorReviewer] == %{
               reviewed_count: 4,
               rejection_count: 0,
               rejection_rate: 0.0,
               no_verdict_count: 2,
               no_verdict_rate: 0.5
             }

      assert ledger[ClaudeReviewer].no_verdict_count == 0
      assert ledger[ClaudeReviewer].no_verdict_rate == 0.0
    end

    test "a verdict-less run with a non-stuck reason is not counted as a gated review" do
      # reviewer_adapter set but the run died for another reason (e.g. the whole
      # job timed out) — no verdict, not review_stuck, so it never gated a review.
      records = [
        record(reviewer_adapter: GrokReviewer, verdict: :approve),
        record(reviewer_adapter: GrokReviewer, verdict: nil, reason: :timed_out)
      ]

      ledger = AgentKPI.aggregate_reviewer_rejections(records)

      assert ledger[GrokReviewer].reviewed_count == 1
      assert ledger[GrokReviewer].no_verdict_count == 0
    end

    test "empty input returns an empty ledger" do
      assert AgentKPI.aggregate_reviewer_rejections([]) == %{}
    end

    test "rating_means/1 is reusable over a bare list of ratings maps" do
      assert AgentKPI.rating_means([%{"a" => 2}, %{"a" => 4, "b" => 10}]) == %{"a" => 3.0, "b" => 10.0}
      assert AgentKPI.rating_means([]) == %{}
    end
  end

  describe "aggregate_review_stuck_causes/1" do
    test "counts review_stuck records by persisted cause without reviewer attribution" do
      records = [
        record(
          reviewer_adapter: nil,
          verdict: nil,
          reason:
            {:review_stuck, "No cross-family reviewer adapter available: {:reviewer_unavailable, #{inspect(Claude)}}"}
        ),
        record(
          reviewer_adapter: nil,
          verdict: nil,
          reason: {:review_stuck, "No cross-family reviewer adapter available: {:no_cross_family_reviewer, :codex}"}
        ),
        record(
          reviewer_adapter: nil,
          verdict: nil,
          reason:
            {:review_stuck,
             "No cross-family reviewer adapter available: {:same_family_reviewer, :claude, #{inspect(Claude)}}"}
        ),
        record(
          reviewer_adapter: nil,
          verdict: nil,
          reason: {:review_stuck, "Reviewer crashed: :killed"}
        ),
        record(reviewer_adapter: ClaudeReviewer, verdict: nil, reason: {:review_stuck, :driver_crashed}),
        record(reviewer_adapter: ClaudeReviewer, verdict: nil, reason: {:review_stuck, :timed_out}),
        record(reviewer_adapter: ClaudeReviewer, verdict: nil, reason: {:review_stuck, :cancelled}),
        record(reviewer_adapter: ClaudeReviewer, verdict: nil, reason: {:review_stuck, :unexpected})
      ]

      assert AgentKPI.aggregate_review_stuck_causes(records) == %{
               reviewer_unavailable: 1,
               no_cross_family_reviewer: 1,
               same_family_reviewer: 1,
               reviewer_crashed: 1,
               driver_crashed: 1,
               timed_out: 1,
               cancelled: 1,
               other: 1
             }

      reviewer_ledger = AgentKPI.aggregate_reviewer_rejections(records)

      refute Map.has_key?(reviewer_ledger, nil)
      assert reviewer_ledger[ClaudeReviewer].no_verdict_count == 4
    end

    test "ignores approved runs and non-stuck failures" do
      records = [
        record(verdict: :approve, reason: :approved),
        record(verdict: :reject, reason: {:review_rejected, "broken"}),
        record(verdict: nil, reason: :timed_out),
        record(verdict: nil, reason: {:review_stuck, :timed_out})
      ]

      assert AgentKPI.aggregate_review_stuck_causes(records) == %{timed_out: 1}
    end

    test "counts direct persisted detail tuple tags" do
      records = [
        record(
          reviewer_adapter: nil,
          verdict: nil,
          reason: {:review_stuck, {:reviewer_unavailable, Claude}}
        ),
        record(
          reviewer_adapter: nil,
          verdict: nil,
          reason: {:review_stuck, {:no_cross_family_reviewer, :codex}}
        ),
        record(
          reviewer_adapter: nil,
          verdict: nil,
          reason: {:review_stuck, {:same_family_reviewer, :codex, Claude}}
        ),
        record(
          reviewer_adapter: ClaudeReviewer,
          verdict: nil,
          reason: {:review_stuck, {:reviewer_crashed, :killed}}
        )
      ]

      assert AgentKPI.aggregate_review_stuck_causes(records) == %{
               reviewer_unavailable: 1,
               no_cross_family_reviewer: 1,
               same_family_reviewer: 1,
               reviewer_crashed: 1
             }
    end
  end

  describe "aggregate/1 reviewer-flaked attribution" do
    test "a review_stuck run does not debit the implementer's success_rate" do
      records = [
        # The implementer exited fine on both; the reviewer wrote a verdict once
        # (approve) and flaked once (review_stuck). Only the gated run counts
        # against the implementer.
        record(agent: :codex, verdict: :approve, reason: :approved),
        record(agent: :codex, verdict: nil, reason: {:review_stuck, "reviewer wrote no verdict"})
      ]

      kpi = AgentKPI.aggregate(records)[:codex]

      assert kpi.run_count == 2
      assert kpi.reviewer_flaked == 1
      # 1 approve over 1 attributable run, NOT 1/2 — the flake is the reviewer's.
      assert kpi.success_rate == 1.0
      assert kpi.first_attempt_pass_rate == 1.0
    end

    test "a genuine implementer failure (reject) still debits success_rate" do
      records = [
        record(agent: :codex, verdict: :approve, reason: :approved),
        record(agent: :codex, verdict: :reject, reason: {:review_rejected, "broken"}),
        record(agent: :codex, verdict: nil, reason: {:review_stuck, "no artifact"})
      ]

      kpi = AgentKPI.aggregate(records)[:codex]

      assert kpi.run_count == 3
      assert kpi.reviewer_flaked == 1
      # 1 approve over 2 attributable (approve + reject); the stuck run is excluded.
      assert kpi.success_rate == 0.5
    end

    test "an implementer whose every run was reviewer-flaked reports 0.0 over 0 attributable" do
      records = [
        record(agent: :pi, verdict: nil, reason: {:review_stuck, "no artifact"}),
        record(agent: :pi, verdict: nil, reason: {:review_stuck, "no artifact"})
      ]

      kpi = AgentKPI.aggregate(records)[:pi]

      assert kpi.run_count == 2
      assert kpi.reviewer_flaked == 2
      assert kpi.success_rate == 0.0
      assert kpi.first_attempt_pass_rate == 0.0
    end
  end

  describe "aggregate_ceremony_cost/1" do
    @reviewer_transcript ~s({"type":"result","usage":{"input_tokens":100,"output_tokens":40}}\n)

    test "sums implementer, reviewer, and audit components per approved run" do
      records = [
        record(
          run_id: "run-a",
          task_id: "42",
          verdict: :approve,
          token_usage: tokens(600, 400),
          reviewer_adapter: Claude,
          reviewer_output: @reviewer_transcript
        ),
        record(
          run_id: "run-b",
          task_id: "43",
          verdict: :approve,
          token_usage: tokens(200, 100),
          reviewer_adapter: Claude,
          reviewer_output: @reviewer_transcript
        ),
        record(run_id: "run-c", task_id: "44", verdict: :reject, token_usage: tokens(900, 900))
      ]

      cost = AgentKPI.aggregate_ceremony_cost(records)

      assert cost.run_count == 2
      assert [%{task_id: "42", run_id: "run-a"}, %{task_id: "43", run_id: "run-b"}] = cost.per_task

      [a, b] = cost.per_task
      assert a.tokens == %{implementer: 1000, reviewer: 140, audit: 0}
      assert a.total == 1140
      assert b.tokens == %{implementer: 300, reviewer: 140, audit: 0}
      assert b.total == 440
    end

    test "reports median and p90 over per-run ceremony totals" do
      records = [
        record(
          run_id: "run-1",
          verdict: :approve,
          token_usage: tokens(100, 100),
          reviewer_adapter: Claude,
          reviewer_output: @reviewer_transcript
        ),
        record(
          run_id: "run-2",
          verdict: :approve,
          token_usage: tokens(300, 300),
          reviewer_adapter: Claude,
          reviewer_output: @reviewer_transcript
        ),
        record(
          run_id: "run-3",
          verdict: :approve,
          token_usage: tokens(500, 500),
          reviewer_adapter: Claude,
          reviewer_output: @reviewer_transcript
        )
      ]

      dist = AgentKPI.aggregate_ceremony_cost(records).distribution

      assert dist.total == %{median: 740.0, p90: 1140}
      assert dist.implementer == %{median: 600.0, p90: 1000}
      assert dist.reviewer == %{median: 140, p90: 140}
      assert dist.audit == %{median: 0, p90: 0}
    end

    test "empty input returns zeroed distribution" do
      assert AgentKPI.aggregate_ceremony_cost([]) == %{
               run_count: 0,
               per_task: [],
               distribution: %{
                 total: %{median: 0, p90: 0},
                 implementer: %{median: 0, p90: 0},
                 reviewer: %{median: 0, p90: 0},
                 audit: %{median: 0, p90: 0}
               }
             }
    end

    test "ceremony_tokens/1 treats missing reviewer_output as zero reviewer spend" do
      tokens =
        AgentKPI.ceremony_tokens(record(verdict: :approve, token_usage: tokens(50, 50), reviewer_adapter: Claude))

      assert tokens == %{implementer: 100, reviewer: 0, audit: 0}
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
