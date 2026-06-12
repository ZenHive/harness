defmodule Harness.Run.DiscernmentStakesGateTest do
  use Harness.RunCase, async: true

  describe "in-run discernment stakes gate (typed d-score + markers)" do
    # The gate reads the structured fields threaded onto the Item — never the
    # rendered prompt prose. `now` == started_at_ms keeps long_running? false so
    # only the d-score / marker branches can pass.
    test "a :security-marked task gates high-stakes even when its prose omits the word" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Harden the lander", prompt: "do it", agent: :claude, markers: [:security]}
      data = %{item: item, started_at_ms: now}

      assert Run.discernment_weight_passes?(data, [], now)
    end

    test "a :bug-marked task gates high-stakes" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Fix the race", prompt: "do it", agent: :claude, markers: [:bug]}
      data = %{item: item, started_at_ms: now}

      assert Run.discernment_weight_passes?(data, [], now)
    end

    test "a task whose body merely mentions 'bug' in prose does not false-positive" do
      now = System.monotonic_time(:millisecond)

      item = %Item{
        id: "1",
        title: "Tidy docs",
        prompt: "Note: we fixed a bug here once. No security impact.",
        agent: :claude,
        body: "we fixed a bug here once",
        d: 2,
        markers: []
      }

      data = %{item: item, started_at_ms: now}

      refute Run.discernment_weight_passes?(data, [], now)
    end

    test "the typed d-score passes the gate at or above min_weight" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Hard task", prompt: "do it", agent: :claude, d: 6, markers: []}
      data = %{item: item, started_at_ms: now}

      assert Run.discernment_weight_passes?(data, [min_weight: 6], now)
      refute Run.discernment_weight_passes?(data, [min_weight: 7], now)
    end

    test "a nil d-score reads as 0 and never trips the weight branch" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Scoreless", prompt: "do it", agent: :claude, d: nil, markers: []}
      data = %{item: item, started_at_ms: now}

      refute Run.discernment_weight_passes?(data, [min_weight: 1], now)
    end

    test "an explicit weight overrides the structured fields" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Whatever", prompt: "do it", agent: :claude, markers: [:security]}
      data = %{item: item, started_at_ms: now}

      refute Run.discernment_weight_passes?(data, [weight: 1, min_weight: 6], now)
      assert Run.discernment_weight_passes?(data, [weight: 9, min_weight: 6], now)
    end
  end

  # Installs `agent_kind` + a fresh parser state into a running gen_statem's
  # data via the OTP :sys test seam. Used to exercise the parsed-event path
  # without spawning a real registered-adapter binary (which would require
  # `agy` / `claude` / etc. on PATH and would race the test timing).
end
