defmodule Harness.RunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  # An adapter whose first invocation builds a command that cannot spawn, then
  # builds a real command on the second attempt. This exercises run-local
  # substrate retry before the lifecycle can settle agent_spawn_failed.
  defmodule TransientSpawnAdapter do
    @moduledoc false
    use Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%{adapter_opts: opts}) do
      counter = Keyword.fetch!(opts, :counter)
      attempt = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

      if attempt == 1 do
        {:ok, {"definitely-not-a-real-binary-xyz", [], []}}
      else
        {:ok, {"/bin/sh", ["-c", "printf agent-work > delivery.txt"], []}}
      end
    end
  end

  # A reviewer double that spawns a real, long-lived process — its handle fires,
  # then it goes silent — to drive the reviewer idle-timeout rotation path
  # (Task 228).
  defmodule SpawnThenIdleReviewer do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.OSProcess

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(_invocation), do: {:ok, {"/bin/sleep", ["30"], []}}

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run), do: OSProcess.kill(run)
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

  # A real, long-lived agent that records its own pid and otherwise idles — lets
  # a test capture the spawned os_pid and assert terminate/1 reaped it on a
  # cancel/lifetime/fail path (Task 201).
  defmodule PidFileAdapter do
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
      {:ok, {"/bin/sh", ["-c", "echo $$ > #{pid_file}; exec sleep 30"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run), do: OSProcess.kill(run)
  end

  defmodule ReportingTerminateAdapter do
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
      owner = Keyword.fetch!(opts, :owner)
      Application.put_env(:harness, :terminate_report_owner, owner)
      {:ok, {"/bin/sh", ["-c", "exec sleep 30"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run) do
      owner = Application.fetch_env!(:harness, :terminate_report_owner)
      send(owner, {:terminated_with_live_port?, Port.info(run.port, :os_pid) != nil})
      OSProcess.kill(run)
    end
  end

  describe "lifecycle — settling on the reviewer's verdict" do
    test "settles :done and removes the worktree when the reviewer approves" do
      result = run([])

      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.review.report == FakeAdapter.review_report("approve")
      assert result.review.ratings == FakeAdapter.review_ratings()
      assert %Outcome{kind: :exited} = result.agent_outcome
      # The reviewer's own settled outcome is captured alongside the implementer's.
      assert %Outcome{kind: :exited} = result.reviewer_outcome
      assert is_binary(result.worktree_path)
      refute File.dir?(result.worktree_path)
    end

    test "retries a transient adapter spawn failure before settling the run" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        run(
          adapter: TransientSpawnAdapter,
          adapter_opts: [counter: counter],
          substrate_retry: [max_retries: 1, base_delay_ms: 1, max_delay_ms: 1]
        )

      assert %Result{state: :done, reason: :approved} = result
      assert Agent.get(counter, & &1) == 2
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

      # The dominant review_stuck mode is a CLEAN reviewer exit with no verdict
      # file — the reviewer's Outcome (raw transcript + kind/exit_status) is
      # captured so the next stuck run is diagnosable (Task 232). `:echo` exits 0
      # after emitting its line; that transcript must survive onto the result.
      assert %Outcome{kind: :exited, exit_status: 0, output: output} = result.reviewer_outcome
      assert output =~ "harness-test"
    end

    test "a malformed verdict artifact settles :failed as review_stuck" do
      result = run(reviewer_adapter_opts: [command: :review_malformed])

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "malformed"
      assert result.review == nil
    end

    # Task 203: a reviewer that exits without the verdict is re-prompted ONCE in
    # the same worktree before the run is discarded — recovering the full
    # implementer+reviewer spend on a recoverable miss.
    test "a missing verdict re-prompts the reviewer once, then settles on its retry verdict" do
      result = run(reviewer_adapter_opts: [command: {:review_miss_then, "approve"}])

      # First pass wrote no artifact; the re-prompt's verdict gates the run.
      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.reviewer_reprompt_count == 1
    end

    # Task 228: a MALFORMED first verdict routes through the SAME re-prompt path a
    # missing one uses — the reviewer's retry writes a valid verdict and gates it.
    test "a malformed verdict re-prompts the reviewer once, then settles on its retry verdict" do
      result = run(reviewer_adapter_opts: [command: {:review_malformed_then, "approve"}])

      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.reviewer_reprompt_count == 1
    end

    test "the re-prompt count is witnessed as a raw fact on the persisted run record" do
      store = file_store()

      {run_id, pid} =
        start(
          reviewer_adapter_opts: [command: {:review_malformed_then, "approve"}],
          result_store: store
        )

      assert %Result{state: :done, reviewer_reprompt_count: 1} = await_result(run_id, pid)
      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)
      assert record.reviewer_reprompt_count == 1
    end

    test "the missing-verdict re-prompt is bounded to exactly one retry (no loop)" do
      result = run(reviewer_adapter_opts: [command: {:review_count_then, :miss}])

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ Review.artifact_path()
      assert result.review == nil
      # Two invocations total: the original pass + exactly one re-prompt.
      assert File.read!(Path.join(result.worktree_path, ".harness/.invoke-count")) == "xx"
    end

    # Task 228: a malformed verdict now re-prompts on the same bounded path a
    # missing one uses — a persistently malformed reviewer re-prompts exactly once,
    # then fails honestly. The bound is real: no loop.
    test "a persistently malformed verdict re-prompts once, then still fails as review_stuck" do
      result = run(reviewer_adapter_opts: [command: {:review_count_then, :malformed}])

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "malformed"
      assert result.review == nil
      # Two invocations total: the original malformed pass + exactly one re-prompt.
      assert File.read!(Path.join(result.worktree_path, ".harness/.invoke-count")) == "xx"
      assert result.reviewer_reprompt_count == 1
    end

    # Task 203 KPI: the fix-diff baseline is captured once at route-into-review,
    # so a first pass that commits fixes then exits without its verdict still has
    # those fixes counted when the re-prompt produces the verdict. A baseline
    # recomputed at the retry's start would span only the (empty) retry → 0.
    test "the fix-diff KPI counts the first pass's fixes across a re-prompt" do
      result = run(reviewer_adapter_opts: [command: {:review_fix_miss_then, "approve"}])

      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.reviewer_diff_size >= 1
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

    test "makes writing the verdict artifact the mandatory, unconditional FINAL action (Task 181)" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      opts =
        base
        |> default_opts()
        |> Keyword.put(:reviewer_adapter_opts, command: {:review_capture_prompt, "approve"})

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, opts)
      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      prompt = GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_prompt.txt"])
      # The root-cause fix for the reviewer-skips-verdict stall: the prompt must
      # frame the artifact write as the unconditional last step before exit.
      assert prompt =~ "FINAL action"
      assert prompt =~ "mandatory and unconditional"
      assert prompt =~ "go idle until the file is written"
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

    test "a project-pinned same-family reviewer is refused" do
      project = ProjectFixture.from_repo(GitFixture.init_repo(), reviewer: :claude)
      {run_id, pid} = start_with_project_reviewer(project, [])

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} =
               await_result(run_id, pid)

      assert report =~ "same_family_reviewer"
    end

    test "a runtime reviewer override wins over a registration default" do
      project = ProjectFixture.from_repo(GitFixture.init_repo(), reviewer: :codex)
      prior = Application.get_env(:harness, :landing_overrides)
      Application.put_env(:harness, :landing_overrides, %{project.name => %{reviewer: :claude}})

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:harness, :landing_overrides)
          value -> Application.put_env(:harness, :landing_overrides, value)
        end
      end)

      {run_id, pid} = start_with_project_reviewer(project, [])

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} =
               await_result(run_id, pid)

      assert report =~ "same_family_reviewer"
    end

    test "a project-pinned reviewer-ineligible agent is refused" do
      project = ProjectFixture.from_repo(GitFixture.init_repo(), reviewer: :codex)
      codex = Harness.AgentAdapter.Codex
      prior = Application.get_env(:harness, :agent_reviewer_ineligible)
      Application.put_env(:harness, :agent_reviewer_ineligible, [:codex])
      :sys.replace_state(Harness.AgentRegistry, &put_in(&1, [:installed, codex], true))

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:harness, :agent_reviewer_ineligible)
          value -> Application.put_env(:harness, :agent_reviewer_ineligible, value)
        end

        Harness.AgentRegistry.reset()
      end)

      {run_id, pid} = start_with_project_reviewer(project, [])

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} =
               await_result(run_id, pid)

      assert report =~ "reviewer_unavailable"
      assert report =~ "Codex"
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

  describe "reviewer idle-timeout floor (Task 181)" do
    test "nil idle (Driver default) is raised to the 10-min reviewing floor" do
      # No caller override would otherwise leave the reviewer on the Driver's
      # 5-min idle default — too tight for a silent cold check run.
      assert Run.reviewer_idle_timeout(nil) == 600_000
    end

    test "an idle override below the floor is raised to the floor" do
      assert Run.reviewer_idle_timeout(150) == 600_000
    end

    test "an idle override above the floor wins" do
      assert Run.reviewer_idle_timeout(900_000) == 900_000
    end

    test "an explicit :infinity idle is preserved" do
      assert Run.reviewer_idle_timeout(:infinity) == :infinity
    end
  end

  describe "reviewing watchdog (Task 199)" do
    test "REGRESSION: a reviewer that never spawns settles :failed within the spawn watchdog, not the lifetime cap" do
      {run_id, pid} =
        start(
          reviewer: HangingAdapter,
          reviewer_spawn_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = await_result(run_id, pid, 5_000)
      assert report =~ "never spawned"
    end

    test "REGRESSION: a reviewer that never produces a verdict settles :failed within the idle watchdog, not the lifetime cap" do
      {run_id, pid} =
        start(
          reviewer_adapter_opts: [command: :sleep],
          reviewing_idle_timeout: 300,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = await_result(run_id, pid, 5_000)
      assert report =~ "no progress"
    end

    test "reviewing_idle_timeout/1 uses the explicit run opt when set" do
      assert Run.reviewing_idle_timeout(%{reviewing_idle_timeout: 42_000, idle_timeout: 150}) == 42_000
    end

    test "reviewing_idle_timeout/1 falls back to the reviewing idle floor when unset" do
      assert Run.reviewing_idle_timeout(%{reviewing_idle_timeout: nil, idle_timeout: nil}) == 600_000
    end

    test "a reviewer whose driver fails settles :failed as review_stuck without waiting for lifetime" do
      result =
        run(
          reviewer_adapter_opts: [command: :missing],
          reviewer_spawn_timeout: 30_000,
          lifetime_timeout: 60_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "Reviewer failed to run"
    end

    test "a reviewer task crash settles :failed as review_stuck without waiting for lifetime" do
      result =
        run(
          reviewer: CrashingAdapter,
          reviewer_spawn_timeout: 30_000,
          lifetime_timeout: 60_000,
          terminal_linger: 100
        )

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "boom in build_command"
    end

    test "reviewer output re-arms the idle watchdog during :reviewing" do
      :ok = RunFeed.subscribe()

      {run_id, pid} =
        start(
          reviewer_adapter_opts: [command: :sleep],
          reviewing_idle_timeout: 400,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      assert_receive {:harness_run_update, %Status{run_id: ^run_id, state: :reviewing}}, 10_000

      for _ <- 1..6 do
        send(pid, {:transcript_chunk, "tick"})
        Process.sleep(150)
        assert {:ok, %Status{state: :reviewing}} = Run.status(run_id)
      end

      assert :ok = Run.cancel(run_id)
      await_result(run_id, pid)
    end
  end

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
          reviewing_idle_timeout: 300,
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

  describe "worktree isolation" do
    test "branches a targeted project from origin target even when local HEAD is stale" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      base = GitFixture.tmp_base()
      stale_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))

      File.write!(Path.join(repo, "landed.txt"), "landed upstream\n")
      GitFixture.git!(repo, ["add", "landed.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "landed upstream"])
      GitFixture.git!(repo, ["push", "-q", "origin", "main"])
      origin_sha = String.trim(GitFixture.git!(origin, ["rev-parse", "main"]))
      GitFixture.git!(repo, ["reset", "--hard", stale_sha])

      project = ProjectFixture.from_repo(repo, target_branch: "main")

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(
          item(),
          project,
          FakeAdapter,
          base |> default_opts() |> Keyword.put(:adapter_opts, command: :echo)
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
      assert String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"])) == stale_sha
      assert String.trim(GitFixture.git!(repo, ["rev-parse", "harness/#{run_id}"])) == origin_sha
    end

    test "target fetch failure falls back to HEAD and the run still starts" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      head_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))
      project = ProjectFixture.from_repo(repo, target_branch: "main")

      log =
        capture_log(fn ->
          {:ok, run_id, pid} =
            Run.Supervisor.start_run(
              item(),
              project,
              FakeAdapter,
              base |> default_opts() |> Keyword.put(:adapter_opts, command: :echo)
            )

          assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
          assert String.trim(GitFixture.git!(repo, ["rev-parse", "harness/#{run_id}"])) == head_sha
        end)

      assert log =~ "harness run: failed to fetch origin/main"
      assert log =~ "falling back to HEAD"
    end

    test "projects without a target branch keep the HEAD base behavior" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      base = GitFixture.tmp_base()
      stale_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))

      File.write!(Path.join(repo, "landed.txt"), "landed upstream\n")
      GitFixture.git!(repo, ["add", "landed.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "landed upstream"])
      GitFixture.git!(repo, ["push", "-q", "origin", "main"])
      origin_sha = String.trim(GitFixture.git!(origin, ["rev-parse", "main"]))
      GitFixture.git!(repo, ["reset", "--hard", stale_sha])

      project = ProjectFixture.from_repo(repo, target_branch: nil)

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(
          item(),
          project,
          FakeAdapter,
          base |> default_opts() |> Keyword.put(:adapter_opts, command: :echo)
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
      assert origin_sha != stale_sha
      assert String.trim(GitFixture.git!(repo, ["rev-parse", "harness/#{run_id}"])) == stale_sha
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

  describe "bounded AI recovery seam — checkout pollution" do
    test "repaired checkout pollution resumes through the reviewer gate" do
      repo = GitFixture.init_repo()

      result =
        run(
          project: ProjectFixture.from_repo(repo),
          checkout_pollution_check: true,
          adapter_opts: [command: {:write_and_pollute_checkout, repo}],
          reviewer_adapter_opts: [command: {:review, "approve"}, recovery_command: :recovery_clean]
        )

      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.recovery_attempts == 1
      assert result.recovery_outcome == :repaired
      assert result.recovery_repaired == "removed leaked.txt"
      assert %TokenUsage{} = result.recovery_token_usage
      assert GitFixture.git!(repo, ["status", "--porcelain"]) == ""
    end

    test "dead checkout pollution settles failed with recovery witness fields" do
      repo = GitFixture.init_repo()

      result =
        run(
          project: ProjectFixture.from_repo(repo),
          checkout_pollution_check: true,
          adapter_opts: [command: {:write_and_pollute_checkout, repo}],
          reviewer_adapter_opts: [command: {:review, "approve"}, recovery_command: :recovery_dead]
        )

      assert %Result{state: :failed, reason: {:checkout_polluted, status}} = result
      assert status =~ "leaked.txt"
      assert result.review == nil
      assert result.recovery_attempts == 1
      assert result.recovery_outcome == :dead
      assert result.recovery_repaired == nil
      assert %TokenUsage{} = result.recovery_token_usage
      assert File.dir?(result.worktree_path)
    end

    test "per-run recovery budget exhaustion fails honestly without spawning recovery" do
      repo = GitFixture.init_repo()

      result =
        run(
          project: ProjectFixture.from_repo(repo),
          checkout_pollution_check: true,
          recovery_budget: 0,
          adapter_opts: [command: {:write_and_pollute_checkout, repo}],
          reviewer_adapter_opts: [command: {:review, "approve"}, recovery_command: :recovery_clean]
        )

      assert %Result{state: :failed, reason: {:checkout_polluted, status}} = result
      assert status =~ "leaked.txt"
      assert result.recovery_attempts == 0
      assert result.recovery_outcome == nil
      assert result.review == nil
    end

    test "reviewer reject bypasses recovery" do
      result =
        run(
          recovery_budget: 1,
          reviewer_adapter_opts: [command: {:review, "reject"}, recovery_command: :recovery_clean]
        )

      assert %Result{state: :failed, reason: {:review_rejected, report}} = result
      assert report == FakeAdapter.review_report("reject")
      assert result.recovery_attempts == 0
      assert result.recovery_outcome == nil
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

  describe "in-run discernment stakes gate (typed d-score + markers)" do
    # The gate reads the structured fields threaded onto the Item — never the
    # rendered prompt prose. `now` == started_at_ms keeps long_running? false so
    # only the d-score / marker branches can pass.
    test "a :security-marked task gates high-stakes even when its prose omits the word" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Harden the lander", prompt: "do it", agent: :claude, markers: [:security]}
      data = %{item: item, started_at_ms: now}

      assert Run.discernment_weight_passes?(data, [], now)
    end

    test "a :bug-marked task gates high-stakes" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Fix the race", prompt: "do it", agent: :claude, markers: [:bug]}
      data = %{item: item, started_at_ms: now}

      assert Run.discernment_weight_passes?(data, [], now)
    end

    test "a task whose body merely mentions 'bug' in prose does not false-positive" do
      now = System.monotonic_time(:millisecond)

      item = %Item{
        id: "1",
        title: "Tidy docs",
        prompt: "Note: we fixed a bug here once. No security impact.",
        agent: :claude,
        body: "we fixed a bug here once",
        d: 2,
        markers: []
      }

      data = %{item: item, started_at_ms: now}

      refute Run.discernment_weight_passes?(data, [], now)
    end

    test "the typed d-score passes the gate at or above min_weight" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Hard task", prompt: "do it", agent: :claude, d: 6, markers: []}
      data = %{item: item, started_at_ms: now}

      assert Run.discernment_weight_passes?(data, [min_weight: 6], now)
      refute Run.discernment_weight_passes?(data, [min_weight: 7], now)
    end

    test "a nil d-score reads as 0 and never trips the weight branch" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Scoreless", prompt: "do it", agent: :claude, d: nil, markers: []}
      data = %{item: item, started_at_ms: now}

      refute Run.discernment_weight_passes?(data, [min_weight: 1], now)
    end

    test "an explicit weight overrides the structured fields" do
      now = System.monotonic_time(:millisecond)
      item = %Item{id: "1", title: "Whatever", prompt: "do it", agent: :claude, markers: [:security]}
      data = %{item: item, started_at_ms: now}

      refute Run.discernment_weight_passes?(data, [weight: 1, min_weight: 6], now)
      assert Run.discernment_weight_passes?(data, [weight: 9, min_weight: 6], now)
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
    {project, overrides} = Keyword.pop(overrides, :project)
    project = project || ProjectFixture.from_repo(GitFixture.init_repo())
    start_with_project(project, overrides)
  end

  defp start_with_project(project, overrides) do
    base = GitFixture.tmp_base()
    {adapter, overrides} = Keyword.pop(overrides, :adapter, FakeAdapter)
    opts = Keyword.merge(default_opts(base), overrides)

    {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, adapter, opts)
    {run_id, pid}
  end

  defp start_with_project_reviewer(project, overrides) do
    base = GitFixture.tmp_base()
    {adapter, overrides} = Keyword.pop(overrides, :adapter, FakeAdapter)

    opts =
      base
      |> default_opts()
      |> Keyword.delete(:reviewer)
      |> Keyword.merge(overrides)

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
    {Harness.ResultStore.Memory,
     root:
       Path.join(
         System.tmp_dir!(),
         "harness-result-store-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
       )}
  end
end
