defmodule Harness.Run.ImplementerIdleTimeoutTest do
  use Harness.RunCase, async: true

  describe "implementer idle-timeout watchdog (Task 239)" do
    test "nil idle is raised to the 10-min implementer floor" do
      assert Run.implementer_idle_timeout(nil) == 600_000
    end

    test "an idle override below the floor is raised to the floor" do
      assert Run.implementer_idle_timeout(150) == 600_000
    end

    test "an idle override above the floor wins" do
      assert Run.implementer_idle_timeout(900_000) == 900_000
    end

    test "an explicit :infinity idle is preserved" do
      assert Run.implementer_idle_timeout(:infinity) == :infinity
    end

    test "a spawned implementer that goes silent settles through the watchdog" do
      {run_id, pid} =
        start(
          adapter_opts: [command: :sleep],
          implementer_idle_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      result = await_result(run_id, pid, 5_000)

      assert %Result{state: :done, reason: :approved} = result
      assert %Outcome{kind: {:timed_out, :idle}} = result.agent_outcome
    end

    test "implementer output re-arms the idle watchdog during :running" do
      {run_id, pid} =
        start(
          adapter_opts: [command: :sleep],
          implementer_idle_timeout: 400,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      await_agent_os_pid(run_id)

      for _ <- 1..6 do
        send(pid, {:transcript_chunk, "tick"})
      end

      assert {:ok, %Status{state: :running}} = Run.status(run_id)

      assert :ok = Run.cancel(run_id)
      assert %Result{state: :failed, reason: :cancelled} = await_result(run_id, pid)
    end
  end
end
