defmodule Harness.RunTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Outcome
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProcessFixture
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Run.Status
  alias Harness.Verification.Check
  alias Harness.Verification.Verdict
  alias Harness.Worktree

  # An adapter whose build_command/1 raises — drives the run's driver-task-crash
  # path (the gen_statem must survive a crashing step task).
  defmodule CrashingAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def build_command(_invocation), do: raise("boom in build_command")

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  # An adapter whose build_command/1 blocks forever — the agent never spawns,
  # so {:run_handle, _} never arrives. Drives the lifetime-timeout
  # force-settle path: the budget must still fire even with `agent_run: nil`.
  defmodule HangingAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def build_command(_invocation) do
      Process.sleep(:infinity)
      {:ok, {"/bin/true", [], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  # An adapter that spawns a real, long-lived agent, then crashes the driver
  # task on the agent's first output — a driver crash *after* the agent's OS
  # process exists, which the run must SIGKILL rather than orphan.
  defmodule DriverCrashAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.OSProcess

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def build_command(%{adapter_opts: opts}) do
      pid_file = Keyword.fetch!(opts, :pid_file)
      # Record the agent's own pid, emit a line so the driver calls
      # classify_message, then stay alive long enough to be orphaned.
      {:ok, {"/bin/sh", ["-c", "echo $$ > #{pid_file}; echo go; exec sleep 30"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({_port, {:data, _data}}, _run), do: raise("crash the driver after the agent spawned")

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run), do: OSProcess.kill(run)
  end

  describe "lifecycle — settling on a verdict" do
    test "settles :done and removes the worktree when verification passes" do
      result = run(checks: [check("ok", "true")])

      assert %Result{state: :done, reason: :passed} = result
      assert %Verdict{status: :pass} = result.verdict
      assert %Outcome{kind: :exited} = result.agent_outcome
      assert is_binary(result.worktree_path)
      refute File.dir?(result.worktree_path)
    end

    test "settles :failed and retains the worktree when verification fails" do
      result = run(checks: [check("ok", "true"), check("no", "false")])

      assert %Result{state: :failed, reason: :verification_red} = result
      assert %Verdict{status: :fail} = result.verdict
      assert File.dir?(result.worktree_path)
      assert Worktree.retained?(result.worktree_path)
    end

    test "verifies the worktree even when the agent times out" do
      result = run(adapter_opts: [command: :write_then_hang], idle_timeout: 150, checks: [check("ok", "true")])

      assert %Result{state: :done, reason: :passed} = result
      assert %Outcome{kind: {:timed_out, :idle}} = result.agent_outcome
    end

    test "carries the rmap task id and run id onto the result" do
      {run_id, pid} = start([])
      result = await_result(run_id, pid)

      assert result.run_id == run_id
      assert result.task_id == "8"
    end

    test "emits a structured run record to the configured store" do
      store = file_store()
      batch_id = "batch-#{System.unique_integer([:positive])}"
      {run_id, pid} = start(batch_id: batch_id, result_store: store)

      assert %Result{state: :done, reason: :passed} = await_result(run_id, pid)
      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)

      assert record.batch_id == batch_id
      assert record.task_id == "8"
      assert record.agent == :claude
      assert record.adapter == FakeAdapter
      assert record.verdict == :pass
      assert record.first_attempt_failed_check_count == 0
      assert record.agent_diff_size > 0
      assert record.failure_cause == %{reason: :passed, failed_checks: []}
    end

    test "the agent's work survives teardown as a commit on the run branch" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), repo, FakeAdapter, default_opts(base))
      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :passed} = result
      # The worktree is gone, but the commit it produced lives on the branch.
      refute File.dir?(result.worktree_path)
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_output.txt"]) =~ "agent-output"
    end

    test "settles :no_changes when the agent produces no diff" do
      result = run(adapter_opts: [command: :echo])

      assert %Result{state: :failed, reason: :no_changes} = result
      assert result.verdict == nil
    end
  end

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
      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), "/no/such/repo", FakeAdapter, opts)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: {:worktree_failed, _reason}} = result
    end

    test "settles :failed when the agent cannot spawn" do
      result = run(adapter_opts: [command: :missing])

      assert %Result{state: :failed, reason: {:agent_spawn_failed, _reason}} = result
      assert result.agent_outcome == nil
    end

    test "settles :failed when verification cannot run" do
      result = run(checks: [])

      assert %Result{state: :failed, reason: {:verification_failed, :no_checks}} = result
    end

    test "settles :failed when the agent's work cannot be committed" do
      result = run(adapter_opts: [command: :break_git])

      assert %Result{state: :failed, reason: {:commit_failed, _reason}} = result
      assert result.verdict == nil
    end

    test "settles :failed without stranding the deliverable when the agent moves HEAD" do
      result = run(adapter_opts: [command: :detach_head])

      assert %Result{
               state: :failed,
               reason: {:commit_failed, {:head_moved, expected_branch, {:detached, sha}}}
             } = result

      assert expected_branch =~ ~r"\Aharness/"
      assert String.match?(sha, ~r/\A[0-9a-f]{40}\z/)
      assert result.verdict == nil
      # The worktree is retained on failure — the agent's work is still
      # inspectable in the working tree rather than lost to a teardown that
      # would have followed an off-branch commit.
      assert Worktree.retained?(result.worktree_path)
      assert File.read!(Path.join(result.worktree_path, "agent_output.txt")) =~ "agent-output"
    end
  end

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
  end

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
  end

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
        checks: [check("ok", "true")],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        verification_timeout: 10_000
      ]

      {:ok, run_id, _pid} = Run.Supervisor.start_run(item(), repo, FakeAdapter, opts)

      assert_receive {:harness_run, ^run_id, %Result{state: :done}}, 5_000
      assert {:ok, %Status{state: :done}} = Run.status(run_id)
      assert :ok = Run.cancel(run_id)
      assert {:ok, %Status{state: :done}} = Run.status(run_id)
    end
  end

  describe "autonomous repair loop" do
    test "a red verdict resumes the agent, and the loop settles :done once repair fixes it" do
      {run_id, pid, repo} =
        start_repair(adapter_opts: [command: :repair], checks: marker_checks(), max_repair_attempts: 2)

      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :passed, repair_attempts: 1} = result
      assert %Verdict{status: :pass} = result.verdict

      # repair_marker exists only because the resumed run saw session: :resume —
      # proof the agent was resumed. Its content is the repair prompt the agent
      # was handed: proof the failing checks were fed back.
      marker = GitFixture.git!(repo, ["show", "harness/#{run_id}:repair_marker"])
      assert marker =~ "repair attempt 1 of 2"
      assert marker =~ "check: marker"
    end

    test "the loop stops at the configured attempt cap" do
      {run_id, pid, _repo} =
        start_repair(adapter_opts: [command: :repair_noop], checks: marker_checks(), max_repair_attempts: 2)

      result = await_result(run_id, pid)

      assert %Result{state: :failed, reason: :verification_red, repair_attempts: 2} = result
      assert %Verdict{status: :fail} = result.verdict
    end

    test "the attempt cap is configurable — 0 disables repair" do
      {run_id, pid, _repo} =
        start_repair(adapter_opts: [command: :repair_noop], checks: marker_checks(), max_repair_attempts: 0)

      result = await_result(run_id, pid)

      assert %Result{state: :failed, reason: :verification_red, repair_attempts: 0} = result
    end

    test "a non-repairable failure ends the loop without burning the attempt budget" do
      # The resumed agent produces no diff (a quota-starved agent): the run
      # settles :no_changes at one attempt — it does not burn all five.
      {run_id, pid, _repo} =
        start_repair(adapter_opts: [command: :repair_quota], checks: marker_checks(), max_repair_attempts: 5)

      result = await_result(run_id, pid)

      assert %Result{state: :failed, reason: :no_changes, repair_attempts: 1} = result
    end

    test "the settled run's status snapshot carries the repair attempt count" do
      {run_id, _pid, _repo} =
        start_repair(
          adapter_opts: [command: :repair_noop],
          checks: marker_checks(),
          max_repair_attempts: 1,
          terminal_linger: 2_000
        )

      assert_receive {:harness_run, ^run_id, %Result{repair_attempts: 1}}, 10_000
      assert {:ok, %Status{state: :failed, repair_attempts: 1}} = Run.status(run_id)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp run(overrides) do
    {run_id, pid} = start(overrides)
    await_result(run_id, pid)
  end

  defp start(overrides) do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    {adapter, overrides} = Keyword.pop(overrides, :adapter, FakeAdapter)
    opts = Keyword.merge(default_opts(base), overrides)

    {:ok, run_id, pid} = Run.Supervisor.start_run(item(), repo, adapter, opts)
    {run_id, pid}
  end

  # Like start/1 but returns the repo too (so a test can `git show` the run
  # branch) and never forces max_repair_attempts — repair-loop tests set it.
  defp start_repair(overrides) do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    opts =
      Keyword.merge(
        [
          base_dir: base,
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          verification_timeout: 10_000,
          terminal_linger: 100
        ],
        overrides
      )

    {:ok, run_id, pid} = Run.Supervisor.start_run(item(), repo, FakeAdapter, opts)
    {run_id, pid, repo}
  end

  # A check stack the :repair fixtures grade against: red until the resumed
  # agent writes repair_marker into the worktree.
  defp marker_checks, do: [check("ok", "true"), check("marker", "test", ["-f", "repair_marker"])]

  defp default_opts(base) do
    [
      base_dir: base,
      adapter_opts: [command: :write],
      checks: [check("ok", "true")],
      total_timeout: 30_000,
      idle_timeout: 10_000,
      lifetime_timeout: 30_000,
      verification_timeout: 10_000,
      terminal_linger: 100,
      # The repair loop has its own describe block; keep the base helpers
      # single-attempt so a red verdict settles straight to :failed.
      max_repair_attempts: 0
    ]
  end

  defp item do
    %Item{id: "8", title: "Supervised run lifecycle", prompt: "do the thing", agent: :claude}
  end

  defp check(name, command, args \\ []), do: %Check{name: name, command: command, args: args}

  defp await_result(run_id, pid, timeout \\ 5_000) do
    ref = Process.monitor(pid)
    assert_receive {:harness_run, ^run_id, %Result{} = result}, timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
    result
  end

  defp await_agent_os_pid(run_id, tries \\ 150)

  defp await_agent_os_pid(_run_id, 0), do: flunk("run never reported an agent os_pid")

  defp await_agent_os_pid(run_id, tries) do
    case Run.status(run_id) do
      {:ok, %Status{state: :running, agent_os_pid: os_pid}} when is_integer(os_pid) ->
        os_pid

      _other ->
        Process.sleep(20)
        await_agent_os_pid(run_id, tries - 1)
    end
  end

  defp await_pid_file(path, tries \\ 200)

  defp await_pid_file(_path, 0), do: flunk("agent never wrote its pid file")

  defp await_pid_file(path, tries) do
    with {:ok, content} <- File.read(path),
         {os_pid, _rest} <- Integer.parse(String.trim(content)) do
      os_pid
    else
      _ ->
        Process.sleep(20)
        await_pid_file(path, tries - 1)
    end
  end

  defp file_store do
    {Harness.ResultStore.File,
     root: Path.join(System.tmp_dir!(), "harness-result-store-#{System.unique_integer([:positive])}")}
  end
end
