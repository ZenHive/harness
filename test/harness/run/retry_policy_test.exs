defmodule Harness.Run.RetryPolicyTest do
  # async: false because the config-defaults tests mutate the :retry_policy app env.
  use ExUnit.Case, async: false

  alias Harness.Run.RetryPolicy

  # Task 163: RetryPolicy is mechanical backoff arithmetic only. Settled verdicts
  # are never re-run by policy code — judgment about what a failure means lives
  # with the cross-family reviewer (docs/reviewer-pair-architecture.md).

  describe "new/1" do
    test "builds from explicit opts" do
      policy = RetryPolicy.new(max_retries: 2, base_delay_ms: 10, max_delay_ms: 100, multiplier: 2.0)

      assert %RetryPolicy{max_retries: 2, base_delay_ms: 10, max_delay_ms: 100, multiplier: 2.0} = policy
    end

    test "falls back to module defaults when opts and config are silent" do
      prior = Application.get_env(:harness, :retry_policy)
      Application.delete_env(:harness, :retry_policy)
      on_exit(fn -> restore_env(prior) end)

      policy = RetryPolicy.new()

      assert %RetryPolicy{max_retries: 3, base_delay_ms: 1_000, max_delay_ms: 60_000, multiplier: 2.0} = policy
    end

    test "application config overrides module defaults; explicit opts override both" do
      prior = Application.get_env(:harness, :retry_policy)
      Application.put_env(:harness, :retry_policy, max_retries: 7, base_delay_ms: 42)
      on_exit(fn -> restore_env(prior) end)

      from_config = RetryPolicy.new()
      assert from_config.max_retries == 7
      assert from_config.base_delay_ms == 42

      from_opts = RetryPolicy.new(max_retries: 1)
      assert from_opts.max_retries == 1
      assert from_opts.base_delay_ms == 42
    end
  end

  describe "backoff_ms/2" do
    test "grows exponentially from base_delay_ms by multiplier per attempt" do
      policy = RetryPolicy.new(max_retries: 5, base_delay_ms: 10, max_delay_ms: 1_000, multiplier: 2.0)

      assert RetryPolicy.backoff_ms(policy, 1) == 10
      assert RetryPolicy.backoff_ms(policy, 2) == 20
      assert RetryPolicy.backoff_ms(policy, 3) == 40
      assert RetryPolicy.backoff_ms(policy, 4) == 80
    end

    test "caps at max_delay_ms" do
      policy = RetryPolicy.new(base_delay_ms: 50_000, max_delay_ms: 60_000, multiplier: 4.0)

      assert RetryPolicy.backoff_ms(policy, 1) == 50_000
      assert RetryPolicy.backoff_ms(policy, 2) == 60_000
      assert RetryPolicy.backoff_ms(policy, 3) == 60_000
    end

    test "rejects a zero attempt (attempts are 1-based)" do
      policy = RetryPolicy.new(base_delay_ms: 10, max_delay_ms: 100, multiplier: 2.0)

      assert_raise FunctionClauseError, fn -> RetryPolicy.backoff_ms(policy, 0) end
    end
  end

  describe "retry/2" do
    test "returns a non-error result without retrying" do
      policy = RetryPolicy.new(max_retries: 3, base_delay_ms: 0, max_delay_ms: 0)
      counter = :counters.new(1, [])

      result =
        RetryPolicy.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, :done}
          end,
          policy
        )

      assert result == {:ok, :done}
      assert :counters.get(counter, 1) == 1
    end

    test "retries on error until max_retries is exhausted, then returns the last error" do
      # max_retries: 2 ⇒ attempts 1,2,3 all error (the third is attempt > max_retries).
      policy = RetryPolicy.new(max_retries: 2, base_delay_ms: 0, max_delay_ms: 0)
      counter = :counters.new(1, [])

      result =
        RetryPolicy.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :boom}
          end,
          policy
        )

      assert result == {:error, :boom}
      assert :counters.get(counter, 1) == 3
    end

    test "stops retrying as soon as fun succeeds" do
      policy = RetryPolicy.new(max_retries: 5, base_delay_ms: 0, max_delay_ms: 0)
      counter = :counters.new(1, [])

      result =
        RetryPolicy.retry(
          fn ->
            case :counters.get(counter, 1) do
              n when n < 2 ->
                :counters.add(counter, 1, 1)
                {:error, :retry}

              _ ->
                {:ok, :recovered}
            end
          end,
          policy
        )

      assert result == {:ok, :recovered}
      assert :counters.get(counter, 1) == 2
    end
  end

  defp restore_env(nil), do: Application.delete_env(:harness, :retry_policy)
  defp restore_env(value), do: Application.put_env(:harness, :retry_policy, value)
end
