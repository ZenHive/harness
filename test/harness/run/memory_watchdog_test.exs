defmodule Harness.Run.MemoryWatchdogTest do
  use Harness.RunCase, async: true

  describe "memory watchdog (Task 200)" do
    test "REGRESSION: a run whose spawned tree exceeds the ceiling is force-killed and settles :failed, node survives" do
      # `:sleep` keeps a real agent process alive so the sampler has a live tree
      # to weigh; a 1 KiB ceiling is crossed by any real process, so the
      # watchdog must reap it and settle :failed — not idle/lifetime it out.
      {run_id, pid} =
        start(
          adapter_opts: [command: :sleep],
          mem_threshold_kb: 1,
          mem_sample_interval: 300,
          idle_timeout: 30_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      os_pid = await_agent_os_pid(run_id)

      assert %Result{state: :failed, reason: {:memory_runaway, info}} = await_result(run_id, pid, 5_000)
      assert info.role == :agent
      assert info.os_pid == os_pid
      assert info.rss_kb > 1
      assert info.threshold_kb == 1

      # The whole tree is reaped, not just signalled — no orphan agent survives.
      assert ProcessFixture.await_dead(os_pid) == :ok
    end

    test "a runaway reviewer check tree is force-killed and settles :failed (role: :reviewer)" do
      # The actual 2026-06-04 incident: the reviewer's `check_command` (mix) ran
      # away, not the implementer. `:write` commits fast → :reviewing with a live
      # `:sleep` reviewer the watchdog must catch and attribute to :reviewer.
      {run_id, pid} =
        start(
          reviewer_adapter_opts: [command: :sleep],
          mem_threshold_kb: 1,
          mem_sample_interval: 300,
          reviewing_idle_timeout: 30_000,
          idle_timeout: 30_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:memory_runaway, info}} = await_result(run_id, pid, 8_000)
      assert info.role == :reviewer
      assert info.threshold_kb == 1
    end

    test "a tree under the ceiling is left alone — the run completes normally" do
      # A generous ceiling never trips; the `:write` agent commits and the
      # reviewer approves, proving the watchdog is inert under normal memory.
      result =
        run(
          mem_threshold_kb: 64 * 1024 * 1024,
          mem_sample_interval: 50
        )

      assert %Result{state: :done, reason: :approved} = result
    end
  end
end
