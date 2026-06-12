defmodule Harness.Run.FailureIsolationTest do
  use Harness.RunCase, async: true

  describe "failure isolation" do
    @tag :capture_log
    test "a crashing agent-driver task settles :failed without crashing the run" do
      {run_id, pid} = start(adapter: CrashingAdapter)
      result = await_result(run_id, pid)

      assert %Result{state: :failed, reason: {:driver_crashed, _reason}} = result
    end

    @tag :capture_log
    test "a driver crash after the agent spawned still kills the agent" do
      pid_file = Path.join(System.tmp_dir!(), "harness-run-#{System.unique_integer([:positive])}.pid")
      on_exit(fn -> File.rm(pid_file) end)

      result = run(adapter: DriverCrashAdapter, adapter_opts: [pid_file: pid_file])

      assert %Result{state: :failed, reason: {:driver_crashed, _reason}} = result
      assert ProcessFixture.await_dead(await_pid_file(pid_file)) == :ok
    end

    test "settles :failed when the worktree cannot be created" do
      base = GitFixture.tmp_base()
      opts = Keyword.put(default_opts(base), :terminal_linger, 100)
      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), ProjectFixture.from_repo("/no/such/repo"), FakeAdapter, opts)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: {:worktree_failed, _reason}} = result
    end

    test "settles :failed when the agent cannot spawn" do
      result = run(adapter_opts: [command: :missing])

      assert %Result{state: :failed, reason: {:agent_spawn_failed, _reason}} = result
      assert result.agent_outcome == nil
    end

    test "settles :failed when the agent's work cannot be committed" do
      result = run(adapter_opts: [command: :break_git])

      assert %Result{state: :failed, reason: {:commit_failed, _reason}} = result
      assert result.review == nil
    end

    test "settles with a distinct reason when the worktree disappears before commit" do
      result = run(adapter_opts: [command: :move_cwd_aside])

      assert %Result{state: :failed, reason: {:commit_failed, {:worktree_missing, path}}} = result
      assert path == result.worktree_path
      assert result.review == nil
    end

    test "rejects a run whose cwd vanished after it wrote into a sibling worktree" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo)
      {:ok, sibling} = Worktree.create(project, base_dir: base, id: "sibling-run")

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(
          item(),
          project,
          FakeAdapter,
          base
          |> default_opts()
          |> Keyword.put(:adapter_opts, command: {:write_sibling_and_move_cwd, sibling.path})
        )

      result = await_result(run_id, pid)

      assert %Result{state: :failed, reason: {:commit_failed, {:worktree_missing, path}}} = result
      assert path == result.worktree_path
      assert File.read!(Path.join(sibling.path, "foreign.txt")) =~ "foreign"
      assert_raise RuntimeError, fn -> GitFixture.git!(repo, ["show", "harness/#{run_id}:foreign.txt"]) end
    end

    test "lands the deliverable when the agent detaches HEAD at the run-branch tip" do
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo)
      {run_id, pid} = start_with_project(project, adapter_opts: [command: :detach_head])
      result = await_result(run_id, pid)

      # commit/2 re-attaches the detached HEAD to the run branch losslessly, so
      # the deliverable is committed and the run proceeds through the gate to
      # :done rather than failing on a moved HEAD and stranding the work.
      assert %Result{state: :done, reason: :approved} = result
      assert result.review.verdict == :approve
      # Success tears the worktree down; the deliverable lives on the branch.
      refute File.dir?(result.worktree_path)
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_output.txt"]) =~ "agent-output"
    end
  end
end
