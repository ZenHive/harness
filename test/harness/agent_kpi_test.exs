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
      reason: :passed,
      duration_ms: 100,
      repair_attempts: 0,
      first_attempt_failed_check_count: 0,
      failure_cause: %{reason: :passed, failed_checks: []},
      token_usage: TokenUsage.empty()
    }

    struct!(LogRecord, Map.merge(base, Map.new(fields)))
  end

  describe "aggregate/1 boundaries" do
    test "empty input returns an empty map" do
      assert AgentKPI.aggregate([]) == %{}
    end

    test "an agent with zero :pass runs reports cost_to_green nil, not 0" do
      records = [
        record(agent: :codex, verdict: :fail),
        record(agent: :codex, verdict: nil)
      ]

      kpi = AgentKPI.aggregate(records)

      assert kpi[:codex].run_count == 2
      assert kpi[:codex].success_rate == 0.0
      assert kpi[:codex].first_attempt_pass_rate == 0.0
      assert kpi[:codex].cost_to_green == nil
    end

    test "a passing agent that reported no tokens distinguishes 0.0 from nil cost_to_green" do
      records = [record(agent: :antigravity, verdict: :pass, token_usage: TokenUsage.empty())]

      kpi = AgentKPI.aggregate(records)

      assert kpi[:antigravity].tokens == %{input: 0.0, output: 0.0, total: 0.0}
      assert kpi[:antigravity].cost_to_green == 0.0
    end

    test "a record with a nil token_usage (e.g. a pre-token persisted record) contributes 0 tokens" do
      records = [
        record(agent: :claude, verdict: :pass, token_usage: nil),
        record(agent: :claude, verdict: :pass, token_usage: tokens(100, 100))
      ]

      kpi = AgentKPI.aggregate(records)

      assert kpi[:claude].tokens == %{input: 50.0, output: 50.0, total: 100.0}
      assert kpi[:claude].cost_to_green == 100.0
    end
  end

  describe "aggregate/1 single agent" do
    test "rolls success, first-attempt, duration, token, repair, and cost-to-green metrics" do
      records = [
        record(agent: :claude, verdict: :pass, repair_attempts: 0, duration_ms: 100, token_usage: tokens(600, 400)),
        record(agent: :claude, verdict: :pass, repair_attempts: 1, duration_ms: 200, token_usage: tokens(1200, 800)),
        record(agent: :claude, verdict: :fail, repair_attempts: 2, duration_ms: 300, token_usage: tokens(1800, 1200)),
        record(agent: :claude, verdict: :pass, repair_attempts: 0, duration_ms: 400, token_usage: tokens(2400, 1600))
      ]

      kpi = AgentKPI.aggregate(records)[:claude]

      assert kpi.run_count == 4
      assert kpi.success_rate == 0.75
      assert kpi.first_attempt_pass_rate == 0.5
      assert kpi.duration_ms == %{median: 250.0, p90: 400}
      assert kpi.tokens == %{input: 1500.0, output: 1000.0, total: 2500.0}
      assert kpi.repair_attempts == 0.75
      # mean total tokens across the 3 :pass runs (1000 + 2000 + 4000) / 3
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
        record(agent: :claude, verdict: :pass, duration_ms: 100, token_usage: tokens(100, 100)),
        record(agent: :claude, verdict: :fail, duration_ms: 300, token_usage: tokens(300, 300)),
        record(agent: :codex, verdict: :pass, duration_ms: 50, token_usage: tokens(10, 10))
      ]

      kpi = AgentKPI.aggregate(records)

      assert kpi |> Map.keys() |> Enum.sort() == [:claude, :codex]
      assert kpi[:claude].run_count == 2
      assert kpi[:claude].success_rate == 0.5
      assert kpi[:codex].run_count == 1
      assert kpi[:codex].success_rate == 1.0
      assert kpi[:codex].cost_to_green == 20.0
    end

    test "all-failed agent reports success_rate 0.0 and cost_to_green nil alongside a healthy agent" do
      records = [
        record(agent: :claude, verdict: :pass, token_usage: tokens(500, 500)),
        record(agent: :grok, verdict: :fail),
        record(agent: :grok, verdict: :fail)
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
        record(agent: :claude, verdict: :pass, domains: [:otp]),
        record(agent: :claude, verdict: :fail, domains: [:liveview]),
        record(agent: :codex, verdict: :pass),
        record(agent: :codex, verdict: :pass, domains: [:otp, :ecto])
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
          reason: :passed,
          duration_ms: 100,
          repair_attempts: 0,
          first_attempt_failed_check_count: 0,
          failure_cause: %{reason: :passed, failed_checks: []},
          agent: :claude,
          verdict: :pass,
          token_usage: TokenUsage.empty()
        })

      kpi = AgentKPI.aggregate_by_agent_domain([legacy])

      assert kpi[{:claude, :untagged}].run_count == 1
    end
  end

  describe "aggregate/1 repair-heavy vs first-try" do
    test "first_attempt_pass_rate separates a first-try agent from a repair-heavy one" do
      records = [
        record(agent: :first_try, verdict: :pass, repair_attempts: 0),
        record(agent: :first_try, verdict: :pass, repair_attempts: 0),
        record(agent: :repair_heavy, verdict: :pass, repair_attempts: 2),
        record(agent: :repair_heavy, verdict: :pass, repair_attempts: 3)
      ]

      kpi = AgentKPI.aggregate(records)

      # Both agents land green every time...
      assert kpi[:first_try].success_rate == 1.0
      assert kpi[:repair_heavy].success_rate == 1.0
      # ...but only the first-try agent passes without repairs.
      assert kpi[:first_try].first_attempt_pass_rate == 1.0
      assert kpi[:first_try].repair_attempts == 0.0
      assert kpi[:repair_heavy].first_attempt_pass_rate == 0.0
      assert kpi[:repair_heavy].repair_attempts == 2.5
    end
  end

  defp tokens(input, output) do
    %TokenUsage{input: input, output: output, total: input + output}
  end
end
