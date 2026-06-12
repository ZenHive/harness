defmodule Harness.Run.PerRunTimeoutTest do
  use Harness.RunCase, async: true

  describe "per-run timeout" do
    test "the lifetime budget settles :failed when it elapses" do
      {run_id, pid} = start(adapter_opts: [command: :sleep], lifetime_timeout: 200)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :timed_out} = result
    end

    @tag :capture_log
    test "the lifetime budget force-settles even when the agent run handle never arrives" do
      # HangingAdapter blocks forever in build_command/1, so the driver never
      # calls its :on_spawn hook and {:run_handle, _} never lands in the run's
      # mailbox. Without the force-settle, the run would wedge here forever.
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 200)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :timed_out} = result
      assert result.agent_outcome == nil
    end

    @tag :capture_log
    test "REGRESSION (Task 56): a deferred cancel reply lands when lifetime force-settles before the agent handle arrives" do
      # HangingAdapter never delivers `{:run_handle, _}` → the run enters
      # :running with agent_run=nil → cancel arrives and is deferred → lifetime
      # timer fires → `force_settle_lifetime/1` must reply to the deferred
      # caller AND settle the result with `:timed_out`.
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 6_000)

      wait_until_running(run_id, 50, 5_000)

      cancel_task = Task.async(fn -> Run.cancel(run_id) end)

      assert :ok = Task.await(cancel_task, 10_000)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :timed_out} = result
      assert result.agent_outcome == nil
    end

    @tag :capture_log
    test "interrupt hold before the agent handle arrives is recorded and still times out" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 1_000)

      wait_until_running(run_id, 50, 5_000)

      assert :ok = Run.hold(run_id, true)
      assert {:ok, %Status{state: :running}} = Run.status(run_id)

      assert %Result{state: :failed, reason: :timed_out, agent_outcome: nil} = await_result(run_id, pid)
    end

    @tag :capture_log
    test "duplicate graceful hold before the agent handle arrives is idempotent" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 1_000)

      wait_until_running(run_id, 50, 5_000)

      assert :ok = Run.hold(run_id)
      assert :ok = Run.hold(run_id)

      assert %Result{state: :failed, reason: :timed_out, agent_outcome: nil} = await_result(run_id, pid)
    end

    @tag :capture_log
    test "stale info messages are ignored while a run is active" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 1_000)

      wait_until_running(run_id, 50, 5_000)
      send(pid, :stale_info_message)

      assert {:ok, %Status{state: :running}} = Run.status(run_id)
      assert %Result{state: :failed, reason: :timed_out, agent_outcome: nil} = await_result(run_id, pid)
    end
  end
end
