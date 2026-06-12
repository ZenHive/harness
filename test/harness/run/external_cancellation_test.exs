defmodule Harness.Run.ExternalCancellationTest do
  use Harness.RunCase, async: true

  describe "external cancellation" do
    test "cancel/1 kills the agent and settles :failed" do
      {run_id, pid} = start(adapter_opts: [command: :sleep])
      os_pid = await_agent_os_pid(run_id)

      assert :ok = Run.cancel(run_id)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :cancelled} = result
      assert ProcessFixture.await_dead(os_pid) == :ok
    end

    test "an immediate cancel still settles :cancelled" do
      {run_id, pid} = start(adapter_opts: [command: :sleep])
      assert :ok = Run.cancel(run_id)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :cancelled} = result
    end

    test "cancelling an unknown run is a no-op" do
      assert :ok = Run.cancel("definitely-not-a-run")
    end

    test "REGRESSION (Task 201): cancel during :reviewing terminates the reviewer's spawned tree" do
      # The implementer commits fast → :reviewing with a live reviewer whose
      # os_pid is captured. do_cancel must run terminate_reviewer BEFORE
      # cancel_task so the reviewer process is reaped, not orphaned.
      pid_file = Path.join(System.tmp_dir!(), "harness-rev-#{System.unique_integer([:positive])}.pid")
      on_exit(fn -> File.rm(pid_file) end)

      {run_id, pid} =
        start(
          adapter_opts: [command: :write],
          reviewer: PidFileAdapter,
          reviewer_adapter_opts: [pid_file: pid_file],
          reviewing_idle_timeout: 30_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      reviewer_os_pid = await_pid_file(pid_file)
      assert :ok = Run.cancel(run_id)

      assert %Result{state: :failed, reason: :cancelled} = await_result(run_id, pid)
      assert ProcessFixture.await_dead(reviewer_os_pid) == :ok
    end
  end
end
