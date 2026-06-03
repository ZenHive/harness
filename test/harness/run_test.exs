defmodule Harness.RunTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Outcome
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProcessFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Run.Review
  alias Harness.Run.Status
  alias Harness.Test.CaptureSink
  alias Harness.TokenUsage
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
    def rule_channel, do: :none

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
    def rule_channel, do: :none

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

  # An adapter that spawns a real agent but declares session_resume: false —
  # drives the steer-unsupported path.
  defmodule NoResumeAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.Invocation

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: false}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}), do: {:ok, {"/bin/sleep", ["30"], []}}

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
    def rule_channel, do: :none

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

  describe "lifecycle — settling on the reviewer's verdict" do
    test "settles :done and removes the worktree when the reviewer approves" do
      result = run([])

      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.review.report == FakeAdapter.review_report("approve")
      assert result.review.ratings == FakeAdapter.review_ratings()
      assert %Outcome{kind: :exited} = result.agent_outcome
      assert is_binary(result.worktree_path)
      refute File.dir?(result.worktree_path)
    end

    test "settles :failed and retains the worktree when the reviewer rejects" do
      result = run(reviewer_adapter_opts: [command: {:review, "reject"}])

      assert %Result{state: :failed, reason: {:review_rejected, report}} = result
      assert report == FakeAdapter.review_report("reject")
      assert %Review{verdict: :reject} = result.review
      assert File.dir?(result.worktree_path)
      assert Worktree.retained?(result.worktree_path)
    end

    test "a reviewer that writes no verdict artifact settles :failed as review_stuck" do
      result = run(reviewer_adapter_opts: [command: :echo])

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ Review.artifact_path()
      assert result.review == nil
    end

    test "a malformed verdict artifact settles :failed as review_stuck" do
      result = run(reviewer_adapter_opts: [command: :review_malformed])

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "malformed"
      assert result.review == nil
    end

    test "the reviewer still gates the run when the implementer times out" do
      result = run(adapter_opts: [command: :write_then_hang], idle_timeout: 150)

      assert %Result{state: :done, reason: :approved} = result
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

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)

      assert record.batch_id == batch_id
      assert record.task_id == "8"
      assert record.agent == :claude
      assert record.adapter == FakeAdapter
      assert record.verdict == :approve
      assert record.review_report == FakeAdapter.review_report("approve")
      assert record.review_ratings == FakeAdapter.review_ratings()
      assert record.agent_diff_size > 0
      # The reviewer double changed nothing — first-attempt pass.
      assert record.reviewer_diff_size == 0
      assert record.review_iterations == 0
      # FakeAdapter is not registry-mapped, so its agent_kind is nil and token
      # usage threads through as an empty usage end-to-end — never a crash.
      assert record.token_usage == TokenUsage.empty()
    end

    test "persists the composed input for the initial dispatch" do
      store = file_store()
      {run_id, pid} = start(result_store: store)

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)

      assert [
               %{
                 attempt: 0,
                 phase: :initial,
                 session: nil,
                 rule_channel: :none,
                 prompt: "do the thing",
                 rule_files: [],
                 argv: argv
               }
             ] = record.composed_inputs

      # The captured argv is the adapter's built command (here the fake's
      # sh-wrapped script), not the prompt — the prompt is matched above.
      assert is_list(argv) and argv != []
    end

    test "threads an empty token usage onto the result for an unregistered adapter" do
      result = run([])

      assert %Result{token_usage: %TokenUsage{} = usage} = result
      refute TokenUsage.measured?(usage)
    end

    test "the agent's work survives teardown as a commit on the run branch" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, default_opts(base))

      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :approved} = result
      # The worktree is gone, but the commit it produced lives on the branch.
      refute File.dir?(result.worktree_path)
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_output.txt"]) =~ "agent-output"
    end

    test "the verdict artifact never rides in the deliverable commits" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, default_opts(base))

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      files = GitFixture.git!(repo, ["ls-tree", "-r", "--name-only", "harness/#{run_id}"])
      refute files =~ ".harness/review.json"
    end
  end

  describe "the reviewer's own fixes" do
    test "reviewer fixes are committed on the run branch and measured as reviewer diff" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      store = file_store()

      opts =
        base
        |> default_opts()
        |> Keyword.merge(
          reviewer_adapter_opts: [command: {:review_with_fix, "approve"}],
          result_store: store
        )

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, opts)
      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :approved} = result
      assert result.reviewer_diff_size > 0
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_fix.txt"]) =~ "reviewer-fix"

      # The fix is attributed to the reviewer in the persisted record.
      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)
      assert record.reviewer_diff_size > 0
      assert record.review_iterations == 1
      assert record.reviewer_adapter == FakeAdapter
    end

    test "a clean approve measures zero reviewer diff (first-attempt pass)" do
      result = run([])

      assert %Result{state: :done, reason: :approved, reviewer_diff_size: 0} = result
    end
  end

  describe "the reviewer prompt" do
    test "frames the reviewer with the task, evidence, and the project's check hint" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo, check_command: "mix precommit")

      opts =
        base
        |> default_opts()
        |> Keyword.put(:reviewer_adapter_opts, command: {:review_capture_prompt, "approve"})

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)
      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :approved} = result

      prompt = GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_prompt.txt"])
      assert prompt =~ "You are the cross-family reviewer for a harness run"
      assert prompt =~ "committed work in this SAME worktree"
      assert prompt =~ "Fixing is always cheaper than rejecting"
      assert prompt =~ "Reject ONLY if there is literally nothing to salvage"
      assert prompt =~ "Project check hint"
      assert prompt =~ "mix precommit"
      assert prompt =~ "Task spec:"
      assert prompt =~ "Acceptance criteria:"
      assert prompt =~ "Implementer transcript tail:"
      assert prompt =~ "Diff stat:"
      assert prompt =~ Review.artifact_path()
    end

    test "an empty implementer diff is framed as the reviewer's judgment call" do
      result =
        run(
          adapter_opts: [command: :echo],
          reviewer_adapter_opts: [command: {:review_capture_prompt, "approve"}]
        )

      assert %Result{state: :done, reason: :approved, agent_diff_size: 0} = result

      # The worktree is removed on approve, but the prompt capture rides on the
      # run branch via the reviewer-fixes commit — read it from the result's
      # review instead: the framing is asserted through the retained worktree
      # on the reject variant below. Here we assert the run settled :done on
      # the reviewer's call, not on a procedural empty-diff branch.
    end

    test "an empty implementer diff the reviewer rejects keeps its framing inspectable" do
      result =
        run(
          adapter_opts: [command: :echo],
          reviewer_adapter_opts: [command: {:review_capture_prompt, "reject"}]
        )

      assert %Result{state: :failed, reason: {:review_rejected, _report}, agent_diff_size: 0} = result

      # Failure retains the worktree — the empty-diff framing is inspectable.
      prompt = File.read!(Path.join(result.worktree_path, "reviewer_prompt.txt"))
      assert prompt =~ "The implementer produced NO diff"
      assert prompt =~ "Decide"
      assert prompt =~ "what the empty diff means"
    end
  end

  describe "reviewer selection" do
    test "no cross-family reviewer available settles failed without silently approving" do
      Enum.each(Harness.AgentRegistry.all(), &Harness.AgentRegistry.mark_unavailable(&1, :test_unavailable))
      on_exit(fn -> Harness.AgentRegistry.reset() end)

      result = run(reviewer: nil)

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} = result
      assert report =~ "No cross-family reviewer adapter available"
    end

    test "an explicit same-family reviewer is refused — the gate must be cross-family" do
      # item.agent is :claude; :claude as reviewer is the same family.
      result = run(reviewer: :claude)

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "same_family_reviewer"
    end

    test "prioritize_reviewers/2 sinks a high-rejection-rate reviewer below a cleaner one" do
      candidates = [{:codex, CodexReviewer}, {:cursor, CursorReviewer}, {:grok, GrokReviewer}]

      # codex rejects freely, grok never; cursor is unmeasured (defaults 0.0).
      rates = %{CodexReviewer => 0.8, GrokReviewer => 0.0}

      ordered = Run.prioritize_reviewers(candidates, rates)

      # grok (0.0) and the unmeasured cursor (0.0) keep registry order ahead of
      # the high-rejection codex, which sinks to last.
      assert ordered == [{:cursor, CursorReviewer}, {:grok, GrokReviewer}, {:codex, CodexReviewer}]
    end

    test "prioritize_reviewers/2 preserves registry order when there is no rejection data" do
      candidates = [{:codex, CodexReviewer}, {:cursor, CursorReviewer}]

      # Empty rates → every candidate defaults to 0.0 → stable sort is a no-op.
      assert Run.prioritize_reviewers(candidates, %{}) == candidates
    end

    test "a reviewer-ineligible agent is never auto-selected as the gate (Task 182)" do
      # A cross-family reviewer is normally auto-selected from the registry;
      # marking every agent reviewer-ineligible removes them all and settles
      # review_stuck rather than handing the gate to an ineligible agent. Proves
      # eligibility — not availability — gates selection. Drives the live env
      # cache (:agent_reviewer_ineligible) that AgentSettings.reviewer_eligible?/1
      # reads, so no file is written to the operator's real ~/.harness store.
      ineligible = Enum.map(Harness.AgentRegistry.agents(), fn {agent, _module} -> agent end)
      prior = Application.get_env(:harness, :agent_reviewer_ineligible)
      Application.put_env(:harness, :agent_reviewer_ineligible, ineligible)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:harness, :agent_reviewer_ineligible)
          value -> Application.put_env(:harness, :agent_reviewer_ineligible, value)
        end
      end)

      result = run(reviewer: nil)

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} = result
      assert report =~ "No cross-family reviewer adapter available"
    end
  end

  describe "worktree isolation" do
    test "Antigravity dispatch fails fast without polluting the main checkout" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), Antigravity, default_opts(base))

      result = await_result(run_id, pid)

      assert %Result{
               state: :failed,
               reason: {:agent_spawn_failed, {:worktree_isolation_unsupported, Antigravity, _message}}
             } = result

      assert GitFixture.git!(repo, ["status", "--porcelain"]) == ""
    end

    test "REGRESSION (Task 66): skips pollution detection for adapters declaring worktree isolation" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(
          item(),
          ProjectFixture.from_repo(repo),
          FakeAdapter,
          base
          |> default_opts()
          |> Keyword.put(:adapter_opts, command: {:write_and_pollute_checkout, repo})
        )

      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :approved} = result
      assert GitFixture.git!(repo, ["status", "--porcelain"]) =~ "leaked.txt"
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

    test "settles :failed without stranding the deliverable when the agent moves HEAD" do
      result = run(adapter_opts: [command: :detach_head])

      assert %Result{
               state: :failed,
               reason: {:commit_failed, {:head_moved, expected_branch, {:detached, sha}}}
             } = result

      assert expected_branch =~ ~r"\Aharness/"
      assert String.match?(sha, ~r/\A[0-9a-f]{40}\z/)
      assert result.review == nil
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

    @tag :capture_log
    test "REGRESSION (Task 56): a deferred cancel reply lands when lifetime force-settles before the agent handle arrives" do
      # HangingAdapter never delivers `{:run_handle, _}` → the run enters
      # :running with agent_run=nil → cancel arrives and is deferred → lifetime
      # timer fires → `force_settle_lifetime/1` must reply to the deferred
      # caller AND settle the result with `:timed_out`.
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 300)

      wait_until_running(run_id, 50, 5_000)

      cancel_task = Task.async(fn -> Run.cancel(run_id) end)

      assert :ok = Task.await(cancel_task, 5_000)

      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: :timed_out} = result
      assert result.agent_outcome == nil
    end
  end

  describe "reflex floor" do
    @tag :capture_log
    test "progress stall settles failed and routes a blocked event at the cap" do
      Application.put_env(:harness, :notification_sinks, [CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

      on_exit(fn ->
        Application.delete_env(:harness, :notification_sinks)
        Application.delete_env(:harness, :test_capture_pid)
      end)

      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo, name: "reflex-#{System.unique_integer([:positive])}")

      :ok = ProjectRegistry.register(project)
      on_exit(fn -> ProjectRegistry.unregister(project.name) end)

      opts =
        base
        |> default_opts()
        |> Keyword.merge(adapter_opts: [command: :flood], progress_timeout: 250, land_attempt: 2)

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)

      assert %Result{
               state: :failed,
               reason: {:reflex_halted, :progress_stalled},
               agent_outcome: %Outcome{kind: {:reflex_halted, :progress_stalled}}
             } = await_result(run_id, pid)

      assert_receive {:notify, %Harness.Notification.Event{type: :blocked, task_id: "8", land_attempt: 2}}
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

    test "lifetime timer stays suspended while :held and re-arms on resume" do
      {held_run_id, held_pid} =
        start(
          adapter_opts: [command: :sleep],
          lifetime_timeout: 500,
          max_hold_timeout: 30_000,
          terminal_linger: 100
        )

      wait_until_running(held_run_id)
      # Interrupt-hold parks synchronously only once the agent handle has
      # arrived — without this await, hold is deferred and status races.
      await_agent_os_pid(held_run_id)
      assert :ok = Run.hold(held_run_id, true)
      assert {:ok, %Status{state: :held}} = Run.status(held_run_id)

      Process.sleep(600)

      assert {:ok, %Status{state: :held}} = Run.status(held_run_id)
      assert :ok = Run.cancel(held_run_id)
      await_result(held_run_id, held_pid)

      gate = Path.join(System.tmp_dir!(), "resume-gate-#{System.unique_integer([:positive])}")

      {run_id, pid} =
        start(
          adapter_opts: [command: {:write_then_wait_for_file, gate}],
          lifetime_timeout: 500,
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

  describe "transcript/1 (dashboard backfill snapshot)" do
    test "unknown run id resolves to :not_found" do
      assert {:error, :not_found} = Run.transcript("definitely-not-a-run")
    end

    @tag :capture_log
    test "a fresh run reports an empty buffer with seq 0 before any chunks land" do
      {run_id, _pid} = start(adapter: HangingAdapter, lifetime_timeout: 2_000)
      wait_until_running(run_id, 20, 2_000)

      assert {:ok, %{buffer: <<>>, seq: 0}} = Run.transcript(run_id)
    end

    @tag :capture_log
    test "synthetic {:transcript_chunk, _} appends to the buffer and increments seq" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 5_000)
      wait_until_running(run_id, 20, 5_000)

      send(pid, {:transcript_chunk, "one"})
      send(pid, {:transcript_chunk, "two"})
      send(pid, {:transcript_chunk, "three"})

      # The handler runs in the gen_statem's mailbox order, so a follow-up
      # :gen_statem.call only returns after all queued info messages drain.
      assert {:ok, %{buffer: "onetwothree", seq: 3}} = Run.transcript(run_id)
    end

    @tag :capture_log
    test "broadcasts carry seq so subscribers can dedup against the backfill snapshot" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 5_000)
      wait_until_running(run_id, 20, 5_000)

      :ok = Transcript.subscribe(run_id)

      send(pid, {:transcript_chunk, "alpha"})
      send(pid, {:transcript_chunk, "beta"})

      assert_receive {:harness_transcript, ^run_id, 1, "alpha"}, 1_000
      assert_receive {:harness_transcript, ^run_id, 2, "beta"}, 1_000

      assert {:ok, %{buffer: "alphabeta", seq: 2}} = Run.transcript(run_id)
    end

    @tag :capture_log
    test "the buffer is trimmed to 200 KiB but seq keeps counting every chunk" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 10_000)
      wait_until_running(run_id, 20, 5_000)

      cap = Transcript.buffer_bytes()
      chunk_size = 64 * 1024
      chunk_count = div(cap, chunk_size) + 2

      for i <- 1..chunk_count do
        send(pid, {:transcript_chunk, <<i::8, String.duplicate("x", chunk_size - 1)::binary>>})
      end

      assert {:ok, %{buffer: buffer, seq: seq}} = Run.transcript(run_id)
      assert byte_size(buffer) == cap
      assert seq == chunk_count
    end
  end

  describe "transcript_events/1 (parsed event surface, Task 87)" do
    test "unknown run id resolves to :not_found" do
      assert {:error, :not_found} = Run.transcript_events("definitely-not-a-run")
    end

    @tag :capture_log
    test "an unregistered adapter degrades gracefully to agent_kind: nil + empty events" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 2_000)
      wait_until_running(run_id, 20, 2_000)

      # HangingAdapter is a test-local module not in Harness.AgentRegistry —
      # Run.init/1 resolves its agent_kind to nil so parse_chunk/2 skips
      # parsing and threads existing state untouched. The raw transcript
      # surface still works (covered above); the events surface stays empty.
      send(pid, {:transcript_chunk, "raw bytes that the parser never sees"})

      assert {:ok, %{events: [], agent_kind: nil, seq: 1}} = Run.transcript_events(run_id)
    end

    @tag :capture_log
    test "registered adapter (Antigravity) threads parser_state across chunks and broadcasts events" do
      # Antigravity IS in AgentRegistry → Run.init/1 resolves agent_kind to
      # :antigravity and initializes the Passthrough parser state. The actual
      # `agy` binary never runs because HangingAdapter is what we plug in for
      # the gen_statem's lifecycle; we use :sys.replace_state/2 to install the
      # parser surface that a real Antigravity run would have set up. This
      # exercises the actual handle_common(:transcript_chunk, ...) path through
      # the live gen_statem mailbox without spawning a real agent.
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 3_000)
      wait_until_running(run_id, 20, 3_000)

      install_agent_kind(pid, :antigravity)

      :ok = Transcript.subscribe(run_id)

      send(pid, {:transcript_chunk, "first chunk"})
      send(pid, {:transcript_chunk, "second chunk"})

      assert_receive {:harness_transcript_events, ^run_id, 1, [{:plain_text, %{text: "first chunk"}}]}, 1_000
      assert_receive {:harness_transcript_events, ^run_id, 2, [{:plain_text, %{text: "second chunk"}}]}, 1_000

      assert {:ok, %{events: events, agent_kind: :antigravity, seq: 2}} = Run.transcript_events(run_id)

      assert events == [
               {:plain_text, %{text: "first chunk"}},
               {:plain_text, %{text: "second chunk"}}
             ]
    end

    @tag :capture_log
    test "no event broadcast for an unregistered-adapter run (no :harness_transcript_events on the wire)" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 2_000)
      wait_until_running(run_id, 20, 2_000)

      :ok = Transcript.subscribe(run_id)

      send(pid, {:transcript_chunk, "raw"})

      # Raw broadcast still fires (legacy backbone)…
      assert_receive {:harness_transcript, ^run_id, 1, "raw"}, 1_000

      # …but events broadcast does NOT, because agent_kind is nil and the
      # parser path returns an empty delta.
      refute_receive {:harness_transcript_events, _, _, _}, 100
    end
  end

  # Installs `agent_kind` + a fresh parser state into a running gen_statem's
  # data via the OTP :sys test seam. Used to exercise the parsed-event path
  # without spawning a real registered-adapter binary (which would require
  # `agy` / `claude` / etc. on PATH and would race the test timing).
  defp install_agent_kind(pid, kind) do
    :sys.replace_state(pid, fn
      {state, data} when is_atom(state) and is_map(data) ->
        {state, %{data | agent_kind: kind, transcript_parser_state: Parser.init_state(kind)}}
    end)

    _ = Antigravity
    :ok
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp run(overrides) do
    {run_id, pid} = start(overrides)
    await_result(run_id, pid)
  end

  defp start(overrides) do
    repo = GitFixture.init_repo()
    project = ProjectFixture.from_repo(repo)
    base = GitFixture.tmp_base()
    {adapter, overrides} = Keyword.pop(overrides, :adapter, FakeAdapter)
    opts = Keyword.merge(default_opts(base), overrides)

    {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, adapter, opts)
    {run_id, pid}
  end

  # Every run goes through the reviewer gate, so the defaults wire FakeAdapter
  # as both implementer (:write) and reviewer ({:review, "approve"} — a clean
  # approve). FakeAdapter is unregistered, so the cross-family constraint never
  # trips for test doubles.
  defp default_opts(base) do
    [
      base_dir: base,
      adapter_opts: [command: :write],
      reviewer: FakeAdapter,
      reviewer_adapter_opts: [command: {:review, "approve"}],
      total_timeout: 30_000,
      idle_timeout: 10_000,
      lifetime_timeout: 30_000,
      terminal_linger: 100
    ]
  end

  defp item do
    %Item{id: "8", title: "Supervised run lifecycle", prompt: "do the thing", agent: :claude}
  end

  defp await_result(run_id, pid, timeout \\ 10_000) do
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

  # Polls `Run.status/1` until the run reports `state: :running` (worktree
  # carved, agent task spawned), regardless of whether an agent has yet been
  # observed. Used by the cancel-before-handle regression to anchor the cancel
  # at a point where `agent_run` is still nil so the cancel must be deferred.
  defp wait_until_running(run_id), do: wait_until_running(run_id, 20, 2_000)

  defp wait_until_running(run_id, interval_ms, total_ms) when total_ms > 0 do
    case Run.status(run_id) do
      {:ok, %Status{state: :running}} ->
        :ok

      _other ->
        Process.sleep(interval_ms)
        wait_until_running(run_id, interval_ms, total_ms - interval_ms)
    end
  end

  defp wait_until_running(_run_id, _interval_ms, _total_ms), do: flunk("run never reached state: :running")

  defp await_held(run_id, tries \\ 150)

  defp await_held(_run_id, 0), do: flunk("run never reached state: :held")

  defp await_held(run_id, tries) do
    case Run.status(run_id) do
      {:ok, %Status{state: :held}} ->
        :ok

      _other ->
        Process.sleep(20)
        await_held(run_id, tries - 1)
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
     root:
       Path.join(
         System.tmp_dir!(),
         "harness-result-store-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
       )}
  end
end
