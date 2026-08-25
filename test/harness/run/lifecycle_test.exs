defmodule Harness.Run.LifecycleTest do
  use Harness.RunCase, async: true

  alias Harness.Test.IdentityFakeAdapter

  defmodule LanguageCaptureAdapter do
    @moduledoc false

    use Harness.AgentAdapter

    alias Harness.AgentAdapter
    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.Invocation

    @impl AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl AgentAdapter
    def rule_channel, do: :none

    @impl AgentAdapter
    def build_command(%Invocation{} = invocation) do
      command(invocation)
    end

    @spec command(Invocation.t()) :: {:ok, AgentAdapter.command()}
    defp command(%Invocation{log_tag: log_tag} = invocation) do
      cond do
        String.ends_with?(log_tag, "-recovery") -> recovery_command(invocation)
        String.ends_with?(log_tag, "-review") -> reviewer_command(invocation)
        true -> implementer_command(invocation)
      end
    end

    @spec implementer_command(Invocation.t()) :: {:ok, AgentAdapter.command()}
    defp implementer_command(%Invocation{rule_content: rule_content}) do
      {:ok, {"/bin/sh", ["-c", ~S(printf '%s' "$1" > agent_rules.txt), "harness-fake", rule_content], []}}
    end

    @spec recovery_command(Invocation.t()) :: {:ok, AgentAdapter.command()}
    defp recovery_command(%Invocation{rule_content: rule_content}) do
      json = Jason.encode!(%{outcome: "repaired", report: "cleaned fake checkout leak", repaired: "removed leaked.txt"})

      script =
        ~S|mkdir -p .harness; printf '%s' "$1" > recovery_rules.txt; | <>
          ~S|if [ -f "$HARNESS_RECOVERY_REPO/leaked.txt" ]; then mv "$HARNESS_RECOVERY_REPO/leaked.txt" .harness/recovered-leaked.txt; fi; | <>
          ~S|printf '%s' "$2" > .harness/recovery.json|

      {:ok, {"/bin/sh", ["-c", script, "harness-fake", rule_content, json], []}}
    end

    @spec reviewer_command(Invocation.t()) :: {:ok, AgentAdapter.command()}
    defp reviewer_command(%Invocation{rule_content: rule_content, env: env}) do
      json =
        %{"verdict" => "approve", "report" => "captured rules", "ratings" => FakeAdapter.review_ratings()}
        |> IdentityFakeAdapter.bind_fields(env)
        |> Jason.encode!()

      script = ~S(printf '%s' "$1" > reviewer_rules.txt; mkdir -p .harness; printf '%s' "$2" > .harness/review.json)
      {:ok, {"/bin/sh", ["-c", script, "harness-fake", rule_content, json], []}}
    end
  end

  defmodule TestDbEnvCaptureAdapter do
    @moduledoc false

    use Harness.AgentAdapter

    alias Harness.AgentAdapter
    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.Invocation

    @impl AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl AgentAdapter
    def rule_channel, do: :none

    @impl AgentAdapter
    def build_command(%Invocation{env: env, adapter_opts: opts} = invocation) do
      {exe, argv, _env} = command(invocation, Keyword.get(opts, :capture_env, "MIX_TEST_PARTITION"))
      {:ok, {exe, argv, Map.to_list(env)}}
    end

    @spec command(Invocation.t(), String.t()) :: AgentAdapter.command()
    defp command(%Invocation{log_tag: log_tag} = invocation, env_name) do
      if String.ends_with?(log_tag, "-review") do
        reviewer_command(invocation, env_name)
      else
        implementer_command(env_name)
      end
    end

    @spec implementer_command(String.t()) :: AgentAdapter.command()
    defp implementer_command(env_name) do
      script = ~S|partition=$(printenv "$1"); printf 'tapakly_test%s' "$partition" > agent_db.txt|
      {"/bin/sh", ["-c", script, "harness-fake", env_name], []}
    end

    @spec reviewer_command(Invocation.t(), String.t()) :: AgentAdapter.command()
    defp reviewer_command(%Invocation{env: env}, env_name) do
      json =
        %{"verdict" => "approve", "report" => "captured test DB", "ratings" => FakeAdapter.review_ratings()}
        |> IdentityFakeAdapter.bind_fields(env)
        |> Jason.encode!()

      script =
        ~S|partition=$(printenv "$1"); printf 'tapakly_test%s' "$partition" > reviewer_db.txt; | <>
          ~S(mkdir -p .harness; printf '%s' "$2" > .harness/review.json)

      {"/bin/sh", ["-c", script, "harness-fake", env_name, json], []}
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

    test "persists reviewer task proposals after the approved worktree is removed" do
      result = run(reviewer_adapter_opts: [command: {:review_with_proposals, "approve"}])

      assert %Result{state: :done, proposed_tasks: [proposal]} = result
      refute File.dir?(result.worktree_path)
      assert proposal["title"] == "Add reviewer proposal persistence"

      assert {:ok, [record]} = ResultStore.list_run_records(run_id: result.run_id)
      assert record.review_proposed_tasks == [proposal]
      assert {:ok, detail} = Harness.Dispatch.verdict_detail(result.run_id)
      assert detail.proposed_tasks == [proposal]
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
      result = run(adapter_opts: [command: :write_then_hang], implementer_idle_timeout: 150)

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

    # Task 240: requested_model must reach the implementer Invocation, or the
    # adapter's `--model` flag is silently never set and every run uses the
    # agent's default model regardless of the task's pin.
    test "the run threads requested_model onto the implementer invocation" do
      repo = GitFixture.init_repo()

      {run_id, pid} =
        start(
          project: ProjectFixture.from_repo(repo),
          adapter: FakeModelAdapter,
          adapter_opts: [command: :capture_model],
          requested_model: "claude-opus-4-8-thinking-high"
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_model.txt"]) ==
               "claude-opus-4-8-thinking-high"
    end

    test "threads language-filtered rule content onto implementer and reviewer invocations" do
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo, language: :typescript)
      expected = Harness.AgentRules.render_for_languages([:typescript])

      {run_id, pid} =
        start(
          project: project,
          adapter: LanguageCaptureAdapter,
          reviewer: LanguageCaptureAdapter
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_rules.txt"]) == expected
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_rules.txt"]) == expected
    end

    test "isolates same-project runs with distinct test DB partitions for implementer and reviewer" do
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo, name: "tapakly")

      {run_a, pid_a} =
        start(
          project: project,
          adapter: TestDbEnvCaptureAdapter,
          reviewer: TestDbEnvCaptureAdapter,
          run_id: "run-1781945210210-a54845d6"
        )

      {run_b, pid_b} =
        start(
          project: project,
          adapter: TestDbEnvCaptureAdapter,
          reviewer: TestDbEnvCaptureAdapter,
          run_id: "run-1781945210211-b65f019a"
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_a, pid_a)
      assert %Result{state: :done, reason: :approved} = await_result(run_b, pid_b)

      agent_db_a = GitFixture.git!(repo, ["show", "harness/#{run_a}:agent_db.txt"])
      reviewer_db_a = GitFixture.git!(repo, ["show", "harness/#{run_a}:reviewer_db.txt"])
      agent_db_b = GitFixture.git!(repo, ["show", "harness/#{run_b}:agent_db.txt"])
      reviewer_db_b = GitFixture.git!(repo, ["show", "harness/#{run_b}:reviewer_db.txt"])

      assert agent_db_a == "tapakly_test_h_a54845d6"
      assert reviewer_db_a == agent_db_a
      assert agent_db_b == "tapakly_test_h_b65f019a"
      assert reviewer_db_b == agent_db_b
      refute agent_db_a == agent_db_b
    end

    test "uses a project's test DB isolation env override" do
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo, test_db_isolation_env: "APP_TEST_PARTITION")

      {run_id, pid} =
        start(
          project: project,
          adapter: TestDbEnvCaptureAdapter,
          adapter_opts: [capture_env: "APP_TEST_PARTITION"],
          reviewer: TestDbEnvCaptureAdapter,
          reviewer_adapter_opts: [capture_env: "APP_TEST_PARTITION"],
          run_id: "run-1781945210212-c001d00d"
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_db.txt"]) == "tapakly_test_h_c001d00d"
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_db.txt"]) == "tapakly_test_h_c001d00d"
    end

    test "does not inject a test DB partition when the project opts out" do
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo, test_db_isolation_env: false)

      {run_id, pid} =
        start(
          project: project,
          adapter: TestDbEnvCaptureAdapter,
          reviewer: TestDbEnvCaptureAdapter,
          run_id: "run-1781945210213-deadbeef"
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_db.txt"]) == "tapakly_test"
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_db.txt"]) == "tapakly_test"
    end

    test "threads language-filtered rule content onto recovery invocations" do
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo, language: :typescript)
      expected = Harness.AgentRules.render_for_languages([:typescript])

      {run_id, pid} =
        start(
          project: project,
          checkout_pollution_check: true,
          adapter_opts: [command: {:write_and_pollute_checkout, repo}],
          reviewer: LanguageCaptureAdapter
        )

      assert %Result{state: :done, reason: :approved, recovery_outcome: :repaired} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:recovery_rules.txt"]) == expected
    end

    test "the implementer invocation carries no model when the task is unpinned" do
      repo = GitFixture.init_repo()

      {run_id, pid} =
        start(project: ProjectFixture.from_repo(repo), adapter_opts: [command: :capture_model])

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_model.txt"]) == ""
    end

    test "an explicit nil requested_model suppresses the configured model fallback" do
      put_agent_model_env(claude: "claude-opus-4-8-thinking-high")

      assert %Result{state: :done, reason: :approved} = run(requested_model: nil)
    end

    # An unpinned task falls back to the per-agent Config.agent_model default —
    # the implementer-side half of the configurable-model surface. item().agent is
    # :claude, so the :claude default resolves onto the implementer invocation.
    test "an unpinned task falls back to the per-agent configured model" do
      put_agent_model_env(claude: "claude-opus-4-8-thinking-high")

      repo = GitFixture.init_repo()

      {run_id, pid} =
        start(
          project: ProjectFixture.from_repo(repo),
          adapter: FakeModelAdapter,
          adapter_opts: [command: :capture_model]
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_model.txt"]) ==
               "claude-opus-4-8-thinking-high"
    end

    # The reviewer's model comes from the reviewer adapter's OWN agent default,
    # not the implementer's. FakeAdapter is unregistered (no agent mapping), so
    # the reviewer model resolves to nil even with a :claude (the implementer
    # agent) default set — guarding against the reviewer wrongly inheriting the
    # implementer's config.
    test "the reviewer invocation does not inherit the implementer's configured model" do
      put_agent_model_env(claude: "claude-opus-4-8-thinking-high")

      repo = GitFixture.init_repo()

      {run_id, pid} =
        start(
          project: ProjectFixture.from_repo(repo),
          adapter: FakeModelAdapter,
          adapter_opts: [command: :capture_model],
          reviewer_adapter_opts: [command: {:review_capture_model, "approve"}]
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_model.txt"]) == ""
    end

    test "same agent can implement with the shared model and review with the reviewer override" do
      put_agent_model_env(cursor: "composer-2.5-fast")
      put_reviewer_model_env(cursor: "claude-opus-4-8-thinking-high")

      repo = GitFixture.init_repo()
      item = %{item() | agent: :cursor}

      {run_id, pid} =
        start(
          item: item,
          project: ProjectFixture.from_repo(repo),
          adapter: FakeModelAdapter,
          adapter_opts: [command: :capture_model],
          reviewer: FakeModelAdapter,
          reviewer_agent_resolver: fn FakeModelAdapter -> {:ok, :cursor} end,
          reviewer_adapter_opts: [command: {:review_capture_model, "approve"}]
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_model.txt"]) == "composer-2.5-fast"

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_model.txt"]) ==
               "claude-opus-4-8-thinking-high"
    end

    test "in-run invocation env strips ambient GitHub auth for gh" do
      repo = GitFixture.init_repo()

      {run_id, pid} =
        start(
          project: ProjectFixture.from_repo(repo),
          adapter_opts: [command: :capture_github_env],
          env: %{
            "GH_TOKEN" => "caller-gh-token",
            "GITHUB_TOKEN" => "caller-github-token",
            "GH_CONFIG_DIR" => "/tmp/leaky-gh-config"
          }
        )

      assert %Result{state: :done, reason: :approved, worktree_path: worktree_path} = await_result(run_id, pid)

      expected_gh_config_dir = Path.join([worktree_path, ".harness", "gh-config"])

      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_github_env.txt"]) ==
               """
               GH_TOKEN=
               GITHUB_TOKEN=
               GH_CONFIG_DIR=#{expected_gh_config_dir}
               """
    end

    test "makes rmap reachable inside the implementer worktree even when PATH is scrubbed" do
      repo = GitFixture.init_repo()
      rmap_dir = fake_rmap_dir()

      with_rmap_path_dirs([rmap_dir])

      {run_id, pid} =
        start(
          project: ProjectFixture.from_repo(repo),
          adapter_opts: [command: :capture_rmap_path],
          env: %{"PATH" => "/usr/bin:/bin"}
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      captured = GitFixture.git!(repo, ["show", "harness/#{run_id}:agent_rmap_path.txt"])
      assert String.trim(captured) == Path.join(rmap_dir, "rmap")
    end
  end
end
