defmodule Harness.Run.ReviewingWatchdogTest do
  use Harness.RunCase, async: true

  describe "reviewing watchdog (Task 199)" do
    test "REGRESSION: a reviewer that never spawns settles :failed within the spawn watchdog, not the lifetime cap" do
      {run_id, pid} =
        start(
          reviewer: HangingAdapter,
          reviewer_spawn_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = await_result(run_id, pid, 5_000)
      assert report =~ "never spawned"
    end

    test "REGRESSION: a reviewer that never produces a verdict settles :failed within the idle watchdog, not the lifetime cap" do
      {run_id, pid} =
        start(
          reviewer_adapter_opts: [command: :sleep],
          reviewing_idle_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = await_result(run_id, pid, 5_000)
      assert report =~ "no progress"
    end

    test "reviewing_idle_timeout/1 uses the explicit run opt when set" do
      assert Run.reviewing_idle_timeout(%{reviewing_idle_timeout: 42_000, idle_timeout: 150}) == 42_000
    end

    test "reviewing_idle_timeout/1 falls back to the reviewing idle floor when unset" do
      assert Run.reviewing_idle_timeout(%{reviewing_idle_timeout: nil, idle_timeout: nil}) == 600_000
    end

    test "REGRESSION: reviewing(:enter) with an unconfigured model-capable reviewer defers via a gen_statem-legal :state_timeout, never :next_event" do
      # Codex is model-capable and has no reviewer/agent model configured in test
      # env, so the model-required guard fires in the :enter callback. A
      # gen_statem :enter callback may not emit a `{:next_event, …}` action —
      # doing so crashed the run with :bad_state_enter_action_from_state_function.
      # The error branch must instead defer via a zero-delay :state_timeout.
      data = %{
        reviewer_adapter: Codex,
        reviewer_agent_resolver: fn Codex -> {:ok, :missing_model_reviewer} end,
        reason: nil
      }

      assert {:keep_state, %{reason: {:model_required, :missing_model_reviewer}}, actions} =
               Run.reviewing(:enter, :implementing, data)

      assert actions == [{:state_timeout, 0, :reviewer_model_unavailable}]
      refute Enum.any?(actions, &match?({:next_event, _, _}, &1))

      # The deferred timeout settles the run as :failed.
      assert {:next_state, :failed, _} =
               Run.reviewing(:state_timeout, :reviewer_model_unavailable, data)
    end

    test "a reviewer whose driver fails settles :failed as review_stuck without waiting for lifetime" do
      result =
        run(
          reviewer_adapter_opts: [command: :missing],
          reviewer_spawn_timeout: 30_000,
          lifetime_timeout: 60_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "Reviewer failed to run"
    end

    test "a reviewer task crash settles :failed as review_stuck without waiting for lifetime" do
      result =
        run(
          reviewer: CrashingAdapter,
          reviewer_spawn_timeout: 30_000,
          lifetime_timeout: 60_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "boom in build_command"
    end

    test "reviewer output re-arms the idle watchdog during :reviewing" do
      :ok = RunFeed.subscribe()

      {run_id, pid} =
        start(
          reviewer_adapter_opts: [command: :sleep],
          reviewing_idle_timeout: 400,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert_receive {:harness_run_update, %Status{run_id: ^run_id, state: :reviewing}}, 10_000

      for _ <- 1..6 do
        send(pid, {:transcript_chunk, "tick"})
      end

      assert {:ok, %Status{state: :reviewing}} = Run.status(run_id)

      assert :ok = Run.cancel(run_id)
      await_result(run_id, pid)
    end
  end
end
