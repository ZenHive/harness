defmodule Harness.Run.ObservableStateTest do
  use Harness.RunCase, async: true

  describe "observable state" do
    test "status/1 reports the running state and resolves an unknown id" do
      assert {:error, :not_found} = Run.status("definitely-not-a-run")

      {run_id, pid} = start(adapter_opts: [command: :sleep])
      os_pid = await_agent_os_pid(run_id)

      assert {:ok, %Status{state: :running, run_id: ^run_id, task_id: "8"}} = Run.status(run_id)

      assert :ok = Run.cancel(run_id)
      await_result(run_id, pid)

      assert {:error, :not_found} = Run.status(run_id)
      assert ProcessFixture.await_dead(os_pid) == :ok
    end

    test "status/1 and cancel/1 accept a pid as well as a run id" do
      {run_id, pid} = start(adapter_opts: [command: :sleep])
      await_agent_os_pid(run_id)

      assert {:ok, %Status{state: :running}} = Run.status(pid)
      assert :ok = Run.cancel(pid)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :cancelled} = result
    end

    test "a settled run stays observable during the terminal linger window" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      # Omit :lifetime_timeout and :terminal_linger to exercise the config
      # defaults; the default linger keeps the run observable after it settles.
      opts = [
        base_dir: base,
        adapter_opts: [command: :write],
        reviewer: FakeAdapter,
        reviewer_adapter_opts: [command: {:review, "approve"}],
        total_timeout: 30_000,
        idle_timeout: 10_000
      ]

      {:ok, run_id, _pid} = Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, opts)

      assert_receive {:harness_run, ^run_id, %Result{state: :done}}, 10_000
      assert {:ok, %Status{state: :done, review_verdict: :approve}} = Run.status(run_id)
      assert :ok = Run.cancel(run_id)
      assert {:ok, %Status{state: :done}} = Run.status(run_id)
    end

    test "status/1 reports :reviewing while the reviewer works" do
      :ok = RunFeed.subscribe()

      {run_id, pid} =
        start(
          adapter_opts: [command: :write],
          # A reviewer that never finishes keeps the run observable in :reviewing.
          reviewer_adapter_opts: [command: :sleep]
        )

      # The run broadcasts every state transition; :reviewing means the
      # implementer committed and the reviewer is now THE gate.
      assert_receive {:harness_run_update, %Status{run_id: ^run_id, state: :reviewing}}, 10_000
      assert {:ok, %Status{state: :reviewing, review_verdict: nil}} = Run.status(run_id)

      assert :ok = Run.cancel(run_id)
      await_result(run_id, pid)
    end
  end
end
