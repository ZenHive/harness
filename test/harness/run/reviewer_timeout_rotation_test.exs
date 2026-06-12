defmodule Harness.Run.ReviewerTimeoutRotationTest do
  use Harness.RunCase, async: true

  describe "reviewer-timeout rotation (Task 228)" do
    test "a reviewer that never spawns rotates to the next cross-family reviewer" do
      result =
        run(
          reviewer: [HangingAdapter, FakeAdapter],
          reviewer_spawn_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      # HangingAdapter never spawns → the spawn watchdog rotates to FakeAdapter,
      # which writes the approve verdict and gates the run.
      assert %Result{state: :done, reason: :approved, reviewer_adapter: FakeAdapter} = result
      assert result.reviewer_rotation_count == 1
    end

    test "a reviewer that spawns then goes idle rotates to the next cross-family reviewer" do
      result =
        run(
          reviewer: [SpawnThenIdleReviewer, FakeAdapter],
          reviewing_idle_timeout: 1_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      # SpawnThenIdleReviewer spawns then goes silent → the idle watchdog rotates
      # to FakeAdapter, which approves.
      assert %Result{state: :done, reason: :approved, reviewer_adapter: FakeAdapter} = result
      assert result.reviewer_rotation_count == 1
    end

    test "an exhausted rotation slate settles :failed as review_stuck (bounded, no loop)" do
      # A single never-spawning reviewer with no fallback exhausts the slate on the
      # first timeout and fails honestly — rotation never loops.
      result =
        run(
          reviewer: [HangingAdapter],
          reviewer_spawn_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "never spawned"
      assert result.reviewer_rotation_count == 0
    end

    test "the rotation count is witnessed as a raw fact on the persisted run record" do
      store = file_store()

      {run_id, pid} =
        start(
          reviewer: [HangingAdapter, FakeAdapter],
          reviewer_spawn_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100,
          result_store: store
        )

      assert %Result{state: :done} = await_result(run_id, pid)
      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)
      assert record.reviewer_rotation_count == 1
      assert record.reviewer_adapter == FakeAdapter
    end
  end
end
