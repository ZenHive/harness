defmodule Harness.Run.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.Run.FailureClass
  alias Harness.Run.Result
  alias Harness.Run.RetryPolicy
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict

  @policy RetryPolicy.new(max_retries: 2, base_delay_ms: 10, max_delay_ms: 100, multiplier: 2.0)

  # NOTE (2026-06-02): the quota-detection tests that lived here are deleted.
  # `config :harness, :retry_policy, quota_patterns: []` disables quota
  # classification permanently (regex false-positives on verification output);
  # FailureClass/RetryPolicy.quota_patterns are deprecated pending the
  # phase-15 deletion pass (Task 163). Only the mechanical retry/backoff
  # behavior keeps coverage below.
  describe "FailureClass.classify/2" do
    test "transient driver crash" do
      result = failed(reason: {:driver_crashed, :boom})

      assert FailureClass.classify(result, @policy) == :transient
    end

    test "transient flaky check — verification_red with a timed_out check" do
      verdict = %Verdict{
        status: :fail,
        results: [
          %CheckResult{name: "t", command: "mix", status: :fail, kind: :timed_out, exit_status: nil, output: ""}
        ]
      }

      result = failed(reason: :verification_red, verdict: verdict)

      assert FailureClass.classify(result, @policy) == :transient
    end

    test "terminal verification_red — checks exited with failures" do
      verdict = %Verdict{
        status: :fail,
        results: [
          %CheckResult{name: "t", command: "mix", status: :fail, kind: :exited, exit_status: 1, output: "fail"}
        ]
      }

      result = failed(reason: :verification_red, verdict: verdict)

      assert FailureClass.classify(result, @policy) == :terminal
    end

    test "terminal no_changes and cancelled" do
      assert FailureClass.classify(failed(reason: :no_changes), @policy) == :terminal
      assert FailureClass.classify(failed(reason: :cancelled), @policy) == :terminal
    end

    test "terminal agent_spawn_failed without quota signals" do
      result = failed(reason: {:agent_spawn_failed, :enoent})

      assert FailureClass.classify(result, @policy) == :terminal
    end

    test "ignores benign quota words in the middle of a long agent transcript" do
      # An agent reading source code or docs that contain quota-related words
      # is not a quota signal — quota errors only appear in the agent's
      # terminal output envelope, never embedded in mid-run file reads.
      filler = String.duplicate("a", 100_000)
      transcript = "subscription quota exhausted in source code" <> filler <> "all good, agent done."

      result =
        failed(
          reason: :verification_red,
          verdict: %Verdict{
            status: :fail,
            results: [
              %CheckResult{name: "t", command: "mix", status: :fail, kind: :exited, exit_status: 1, output: "fail"}
            ]
          },
          agent_outcome: outcome(transcript)
        )

      assert FailureClass.classify(result, @policy) == :terminal
    end

    test "ignores benign quota words in a verification check's mid-output" do
      # Verification stdout (e.g. mix test echoing source containing `quota`)
      # is also clipped to its tail before quota-pattern matching.
      filler = String.duplicate("z", 100_000)
      stdout = "Compiling lib/quota_helper.ex" <> filler <> "0 failures, 504 passed"

      verdict = %Verdict{
        status: :fail,
        results: [
          %CheckResult{name: "test", command: "mix", status: :fail, kind: :exited, exit_status: 1, output: stdout}
        ]
      }

      result = failed(reason: :verification_red, verdict: verdict)

      assert FailureClass.classify(result, @policy) == :terminal
    end
  end

  describe "RetryPolicy.decide/3" do
    test "transient failures retry with capped exponential backoff" do
      assert {:retry, 10, 2} = RetryPolicy.decide(@policy, :transient, 1)
      assert {:retry, 20, 3} = RetryPolicy.decide(@policy, :transient, 2)
      assert {:stop, :max_attempts} = RetryPolicy.decide(@policy, :transient, 3)
    end

    test "backoff is capped at max_delay_ms" do
      policy = RetryPolicy.new(base_delay_ms: 50_000, max_delay_ms: 60_000, multiplier: 4.0)

      assert RetryPolicy.backoff_ms(policy, 1) == 50_000
      assert RetryPolicy.backoff_ms(policy, 3) == 60_000
    end

    test "quota exhaustion stops immediately — fail-over, no retry" do
      assert {:failover, :quota_exhausted} = RetryPolicy.decide(@policy, :quota_exhausted, 1)
      assert {:failover, :quota_exhausted} = RetryPolicy.decide(@policy, :quota_exhausted, 99)
    end

    test "terminal failures are not retried" do
      assert {:stop, :terminal} = RetryPolicy.decide(@policy, :terminal, 1)
    end
  end

  describe "RetryPolicy.run/2" do
    test "retries transient failures until success" do
      counter = :ets.new(:retry_counter, [:set, :public])
      :ets.insert(counter, {:n, 0})

      fun = fn ->
        n = :ets.update_counter(counter, :n, 1)
        if n < 3, do: failed(reason: {:driver_crashed, :boom}), else: done([])
      end

      policy = RetryPolicy.new(max_retries: 3, base_delay_ms: 1, max_delay_ms: 5)

      assert {:ok, %Result{state: :done}, 3} = RetryPolicy.run(fun, policy)
    end

    test "does not retry terminal failures" do
      calls = :ets.new(:calls, [:set, :public])

      fun = fn ->
        :ets.insert(calls, {System.unique_integer([:positive]), true})
        failed(reason: :no_changes)
      end

      assert {:error, %Result{reason: :no_changes}, :terminal} = RetryPolicy.run(fun, @policy)
      assert :ets.info(calls, :size) == 1
    end
  end

  describe "injectable policy" do
    test "from_opts uses a per-run keyword policy" do
      opts = [retry_policy: [max_retries: 7, base_delay_ms: 42]]
      policy = RetryPolicy.from_opts(opts)

      assert policy.max_retries == 7
      assert policy.base_delay_ms == 42
    end

    test "from_opts accepts a struct for per-batch sharing" do
      shared = RetryPolicy.new(max_retries: 1)
      assert %RetryPolicy{max_retries: 1} = RetryPolicy.from_opts(retry_policy: shared)
    end
  end

  defp done(overrides) do
    struct(Result, [{:state, :done}, {:reason, :passed}, {:run_id, "r"}, {:task_id, "t"} | overrides])
  end

  defp outcome(text) do
    run = %AgentRun{
      ref: make_ref(),
      adapter: Harness.FakeAdapter,
      port: nil,
      os_pid: nil,
      started_at: System.monotonic_time()
    }

    %Outcome{run: run, output: text, exit_status: 1, kind: :exited}
  end

  defp failed(overrides) do
    defaults = [
      state: :failed,
      reason: {:driver_crashed, :boom},
      run_id: "r",
      task_id: "t",
      agent_outcome: nil,
      verdict: nil
    ]

    struct(Result, Keyword.merge(defaults, overrides))
  end
end
