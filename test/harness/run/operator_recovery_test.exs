defmodule Harness.Run.OperatorRecoveryTest do
  use Harness.RunCase, async: true

  describe "operator recovery — hold / steer / resume" do
    test "graceful hold parks in :held at the next agent settle boundary" do
      gate = Path.join(System.tmp_dir!(), "hold-gate-#{System.unique_integer([:positive])}")

      {run_id, _pid} =
        start(
          adapter_opts: [command: {:write_then_wait_for_file, gate}],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(run_id)
      assert :ok = Run.hold(run_id)
      File.touch!(gate)
      await_held(run_id)

      assert {:ok, %Status{state: :held, held?: true, hold_reason: :graceful, agent_os_pid: nil}} =
               Run.status(run_id)

      on_exit(fn -> File.rm(gate) end)
    end

    test "interrupt hold kills the agent and parks immediately" do
      {run_id, _pid} =
        start(
          adapter_opts: [command: :sleep],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(run_id)
      os_pid = await_agent_os_pid(run_id)
      assert :ok = Run.hold(run_id, true)

      assert {:ok, %Status{state: :held, held?: true, hold_reason: :interrupt, agent_os_pid: nil}} =
               Run.status(run_id)

      assert ProcessFixture.await_dead(os_pid) == :ok
    end

    test "REGRESSION: interrupt hold terminates the agent before cancelling its driver task" do
      on_exit(fn -> Application.delete_env(:harness, :terminate_report_owner) end)

      {run_id, _pid} =
        start(
          adapter: ReportingTerminateAdapter,
          adapter_opts: [owner: self()],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(run_id)
      await_agent_os_pid(run_id)

      assert :ok = Run.hold(run_id, true)
      assert_receive {:terminated_with_live_port?, true}, 5_000
      await_held(run_id)
    end

    test "lifetime timer stays suspended while :held and re-arms on resume" do
      {held_run_id, held_pid} =
        start(
          adapter_opts: [command: :sleep],
          lifetime_timeout: 3_000,
          max_hold_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(held_run_id)
      # Interrupt-hold parks synchronously only once the agent handle has
      # arrived — without this await, hold is deferred and status races.
      await_agent_os_pid(held_run_id)
      assert :ok = Run.hold(held_run_id, true)
      assert {:ok, %Status{state: :held}} = Run.status(held_run_id)

      # Drive one more event through the Run gen_statem; the :held persistence
      # is about surviving events while the lifetime timer is suspended, not
      # wall-clock dwell.
      send(held_pid, {:transcript_chunk, "post-hold event"})

      assert {:ok, %Status{state: :held}} = Run.status(held_run_id)
      assert :ok = Run.cancel(held_run_id)
      await_result(held_run_id, held_pid)

      gate = Path.join(System.tmp_dir!(), "resume-gate-#{System.unique_integer([:positive])}")

      {run_id, pid} =
        start(
          adapter_opts: [command: {:write_then_wait_for_file, gate}],
          lifetime_timeout: 3_000,
          max_hold_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(run_id)
      await_agent_os_pid(run_id)
      assert :ok = Run.hold(run_id, true)
      assert :ok = Run.resume(run_id)
      File.touch!(gate)

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid, 10_000)
      on_exit(fn -> File.rm(gate) end)
    end

    test "steer stashes feedback and resume emits a session-resume operator prompt" do
      store = file_store()

      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo)
      base = GitFixture.tmp_base()

      opts =
        base
        |> default_opts()
        |> Keyword.merge(
          adapter_opts: [command: :operator_steer],
          max_hold_timeout: 30_000,
          result_store: store
        )

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)

      wait_until_running(run_id, 20, 5_000)
      # Resume requires the run to actually be :held — interrupt-hold only parks
      # synchronously after the agent handle arrives, so await it first.
      await_agent_os_pid(run_id)
      assert :ok = Run.hold(run_id, true)
      assert :ok = Run.steer(run_id, "operator note one")
      assert :ok = Run.steer(run_id, "operator note two")
      assert :ok = Run.resume(run_id)

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)

      assert [
               %{attempt: 0, phase: :initial, session: nil},
               %{attempt: 1, phase: :steer, session: :resume, prompt: steer_prompt}
             ] = record.composed_inputs

      assert steer_prompt =~ "operator note two"
      assert steer_prompt =~ "An operator has reviewed your progress"
    end

    test "max_hold_timeout elapsing settles :failed with :hold_expired" do
      {run_id, pid} =
        start(
          adapter_opts: [command: :sleep],
          lifetime_timeout: 30_000,
          max_hold_timeout: 200,
          terminal_linger: 100
        )

      wait_until_running(run_id)
      assert :ok = Run.hold(run_id, true)

      result = await_result(run_id, pid, 5_000)
      assert %Result{state: :failed, reason: :hold_expired} = result
      assert Worktree.retained?(result.worktree_path)
    end

    test "cancel/1 from :held settles :cancelled like any in-flight cancel" do
      :ok = RunFeed.subscribe()

      {run_id, pid} =
        start(
          adapter_opts: [command: :sleep],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(run_id)
      assert :ok = Run.hold(run_id, true)
      assert_receive {:harness_run_update, %Status{run_id: ^run_id, state: :held}}, 5_000
      assert :ok = Run.cancel(run_id)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :cancelled} = result
    end

    test "steer/2 on a session_resume: false adapter returns {:error, :resume_unsupported}" do
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo)
      base = GitFixture.tmp_base()

      opts =
        base
        |> default_opts()
        |> Keyword.put(:adapter_opts, [])

      {:ok, run_id, _pid} = Run.Supervisor.start_run(item(), project, NoResumeAdapter, opts)

      wait_until_running(run_id)
      assert :ok = Run.hold(run_id, true)
      assert {:error, :resume_unsupported} = Run.steer(run_id, "cannot resume")
    end

    test "hold from a terminal run returns {:error, :terminal}" do
      {run_id, pid} = start(terminal_linger: 5_000)

      assert_receive {:harness_run, ^run_id, %Result{state: :done}}, 5_000
      assert Process.alive?(pid)
      assert {:error, :terminal} = Run.hold(run_id)
    end

    test "resume from a non-held run returns {:error, :not_held}" do
      {run_id, _pid} = start(adapter_opts: [command: :sleep], lifetime_timeout: 30_000)
      wait_until_running(run_id)
      assert {:error, :not_held} = Run.resume(run_id)
    end

    test "hold from :held is a no-op" do
      gate = Path.join(System.tmp_dir!(), "hold-noop-gate-#{System.unique_integer([:positive])}")

      {run_id, _pid} =
        start(
          adapter_opts: [command: {:write_then_wait_for_file, gate}],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(run_id)
      _os_pid = await_agent_os_pid(run_id)
      assert :ok = Run.hold(run_id, true)
      await_held(run_id)
      assert :ok = Run.hold(run_id)
      assert {:ok, %Status{state: :held, held?: true}} = Run.status(run_id)
      on_exit(fn -> File.rm(gate) end)
    end
  end
end
