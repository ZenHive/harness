defmodule Harness.Lander.PRTest do
  @moduledoc """
  `:pr` land path: rebase in the detached landing worktree, push
  `origin/harness/<run-id>`, open a PR via stubbed `gh`, never TargetSync or
  push the target. Reuses the Task 189 conflict path.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.AgentAdapter.Claude
  alias Harness.GitFixture
  alias Harness.Lander
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.Notification.Event
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Run.LogRecord
  alias Harness.Test.CaptureSink
  alias Harness.Worktree

  @moduletag :tmp_dir
  @pr_url "https://github.com/acme/harness/pull/7"

  setup %{tmp_dir: tmp_dir} do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    worktree_base = Path.join(tmp_dir, "worktrees")
    previous = snapshot_env()
    Application.put_env(:harness, :worktree, Keyword.put(previous.worktree || [], :base_dir, worktree_base))

    base_sha = sha(repo, "HEAD")

    project = %Project{
      name: "pr-demo",
      source: {:local, repo},
      roadmap_path: tmp_dir,
      languages: [:elixir],
      landing_policy: :pr,
      target_branch: "main"
    }

    {:ok, run_worktree} = Worktree.create(project, id: "run-x")
    File.write!(Path.join(run_worktree.path, "feature.txt"), "work\n")
    GitFixture.git!(run_worktree.path, ["add", "."])
    GitFixture.git!(run_worktree.path, ["commit", "-m", "agent work"])
    branch_tip = sha(run_worktree.path, "HEAD")

    store = {Memory, scope: {:lander_pr_test, self(), System.unique_integer([:positive])}}
    Application.put_env(:harness, :result_store, store)

    pid = self()

    Application.put_env(:harness, :lander_target_sync, fn repo_path, target ->
      send(pid, {:target_sync, repo_path, target})
      :synced
    end)

    on_exit(fn ->
      restore_env(previous)
      Memory.reset(elem(store, 1))
    end)

    request = %{
      project: project,
      run_id: "run-x",
      task_id: "1",
      agent: :claude,
      reviewer: :codex,
      branch: "harness/run-x",
      task_title: "PR task",
      task_body: "do the work",
      acceptance_criteria: ["opens a PR"],
      review_report: "looks good"
    }

    :ok = ResultStore.record_run(log_record(project.name))

    %{
      origin: origin,
      repo: repo,
      base_sha: base_sha,
      branch_tip: branch_tip,
      project: project,
      request: request,
      run_worktree: run_worktree,
      store: store,
      tmp_dir: tmp_dir
    }
  end

  test "rebases, pushes origin/harness/<run-id>, opens a PR, skips TargetSync", ctx do
    stub_gh(fn
      ["pr", "create" | args], _opts ->
        send(self(), {:gh_create, args})
        {@pr_url <> "\n", 0}
    end)

    {script, args_file} = stub_rmap(ctx.tmp_dir, :ok)
    Application.put_env(:harness, :rmap_bin, script)

    assert {:pr_opened, @pr_url} = Lander.land(ctx.request)

    assert sha(ctx.origin, "refs/heads/harness/run-x") == ctx.branch_tip
    assert sha(ctx.origin, "refs/heads/main") == ctx.base_sha

    assert_receive {:gh_create, create_args}
    assert "--base" in create_args
    assert "main" in create_args
    assert "--head" in create_args
    assert "harness/run-x" in create_args
    assert "--title" in create_args
    assert "PR task" in create_args
    body = create_arg_after(create_args, "--body")
    assert body =~ "do the work"
    assert body =~ "opens a PR"
    assert body =~ "looks good"
    assert body =~ "harness-run:run-x"

    assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-x")
    assert record.pr_url == @pr_url
    assert record.pr_writeback == :opened

    recorded = args_file |> File.read!() |> String.split("\n", trim: true)
    assert "--landing-ref" in recorded
    assert @pr_url in recorded

    refute_receive {:target_sync, _repo, _target}, 200
  end

  test "missing gh fails with :gh_not_found and never pushes the target", ctx do
    stub_gh(fn _args, _opts -> :not_found end)

    assert {:gh_failed, :gh_not_found} = Lander.land(ctx.request)
    assert sha(ctx.origin, "refs/heads/main") == ctx.base_sha
    assert branch_exists?(ctx.repo, ctx.request.branch)
    refute_receive {:target_sync, _repo, _target}, 200
  end

  test "unauthenticated gh fails with the observed banner and never pushes the target", ctx do
    output = """
    To get started with GitHub CLI, please run:  gh auth login
    Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.
    """

    stub_gh(fn _args, _opts -> {output, 4} end)

    assert {:gh_failed, {:gh_unauthenticated, failed}} = Lander.land(ctx.request)
    assert failed =~ "gh auth login"
    assert sha(ctx.origin, "refs/heads/main") == ctx.base_sha
    refute_receive {:target_sync, _repo, _target}, 200
  end

  test "a rebase conflict takes the Task 189 {:conflict, _} path", ctx do
    File.write!(Path.join(ctx.run_worktree.path, "README.md"), "branch side\n")
    GitFixture.git!(ctx.run_worktree.path, ["add", "."])
    GitFixture.git!(ctx.run_worktree.path, ["commit", "-m", "branch readme"])

    File.write!(Path.join(ctx.repo, "README.md"), "main side\n")
    GitFixture.git!(ctx.repo, ["add", "."])
    GitFixture.git!(ctx.repo, ["commit", "-m", "main readme"])
    GitFixture.git!(ctx.repo, ["push", "origin", "main"])
    moved_main = sha(ctx.origin, "refs/heads/main")

    Application.put_env(:harness, :lander_resolver, fn _worktree, _opts -> {:error, :no_resolver} end)
    stub_gh(fn _args, _opts -> flunk("gh must not run on a conflict") end)

    assert {:conflict, output} = Lander.land(ctx.request)
    assert is_binary(output)
    assert sha(ctx.origin, "refs/heads/main") == moved_main
    refute_receive {:target_sync, _repo, _target}, 200
  end

  test "an rmap binary that rejects --landing-ref is logged and the land still succeeds", ctx do
    stub_gh(fn ["pr", "create" | _args], _opts -> {@pr_url <> "\n", 0} end)
    {script, _args_file} = stub_rmap(ctx.tmp_dir, :reject_landing_ref)
    Application.put_env(:harness, :rmap_bin, script)

    log =
      capture_log(fn ->
        assert {:pr_opened, @pr_url} = Lander.land(ctx.request)
      end)

    assert log =~ "landing-ref writeback failed"
    assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-x")
    assert record.pr_url == @pr_url
  end

  test "Worker.perform notifies :pr_opened and does not notify :landed", ctx do
    stub_gh(fn ["pr", "create" | _args], _opts -> {@pr_url <> "\n", 0} end)
    {script, _args_file} = stub_rmap(ctx.tmp_dir, :ok)
    Application.put_env(:harness, :rmap_bin, script)
    Application.put_env(:harness, :notification_sinks, [CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())
    :ok = ProjectRegistry.register(ctx.project)

    on_exit(fn ->
      ProjectRegistry.unregister(ctx.project.name)
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
    end)

    args = %{
      "project_name" => ctx.project.name,
      "run_id" => ctx.request.run_id,
      "task_id" => ctx.request.task_id,
      "agent" => "claude",
      "reviewer" => "codex",
      "branch" => ctx.request.branch,
      "land_attempt" => 1,
      "task_title" => ctx.request.task_title,
      "task_body" => ctx.request.task_body,
      "acceptance_criteria" => ctx.request.acceptance_criteria,
      "review_report" => ctx.request.review_report
    }

    assert :ok = LanderWorker.perform(%Oban.Job{args: args})

    assert_receive {:notify, %Event{type: :pr_opened, task_id: "1", outcome: @pr_url}}
    refute_receive {:notify, %Event{type: :landed}}, 200
    assert sha(ctx.origin, "refs/heads/main") == ctx.base_sha
  end

  test "Worker.perform on missing gh cancels with a witnessed reason and retains the branch", ctx do
    stub_gh(fn _args, _opts -> :not_found end)
    Application.put_env(:harness, :notification_sinks, [CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())
    :ok = ProjectRegistry.register(ctx.project)

    on_exit(fn ->
      ProjectRegistry.unregister(ctx.project.name)
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
    end)

    args = %{
      "project_name" => ctx.project.name,
      "run_id" => ctx.request.run_id,
      "task_id" => ctx.request.task_id,
      "agent" => "claude",
      "branch" => ctx.request.branch,
      "land_attempt" => 1
    }

    assert {:cancel, {:gh_failed, :gh_not_found}} = LanderWorker.perform(%Oban.Job{args: args})
    assert sha(ctx.origin, "refs/heads/main") == ctx.base_sha
    assert branch_exists?(ctx.repo, ctx.request.branch)

    assert_receive {:notify, %Event{type: :blocked, outcome: reason}}
    assert reason =~ "PR open failed"
    assert reason =~ "never pushed origin/<target>"
  end

  @spec stub_gh(([String.t()], keyword() -> :not_found | {String.t(), integer()})) :: :ok
  defp stub_gh(fun), do: Application.put_env(:harness, :gh_cmd, fun)

  @spec stub_rmap(String.t(), :ok | :reject_landing_ref) :: {String.t(), String.t()}
  defp stub_rmap(tmp_dir, :ok) do
    script = Path.join(tmp_dir, "rmap")
    args_file = Path.join(tmp_dir, "rmap_args.txt")
    File.write!(script, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{args_file}'\nexit 0\n")
    File.chmod!(script, 0o755)
    {script, args_file}
  end

  defp stub_rmap(tmp_dir, :reject_landing_ref) do
    script = Path.join(tmp_dir, "rmap-reject")
    args_file = Path.join(tmp_dir, "rmap_args.txt")

    File.write!(script, """
    #!/bin/sh
    printf '%s\\n' "$@" > '#{args_file}'
    for arg in "$@"; do
      if [ "$arg" = "--landing-ref" ]; then
        echo 'unknown flag: --landing-ref' >&2
        exit 1
      fi
    done
    exit 0
    """)

    File.chmod!(script, 0o755)
    {script, args_file}
  end

  @spec create_arg_after([String.t()], String.t()) :: String.t()
  defp create_arg_after(args, flag) do
    case Enum.drop_while(args, &(&1 != flag)) do
      [^flag, value | _rest] -> value
      _missing -> flunk("missing #{flag} in #{inspect(args)}")
    end
  end

  @spec sha(String.t(), String.t()) :: String.t()
  defp sha(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  @spec branch_exists?(String.t(), String.t()) :: boolean()
  defp branch_exists?(repo, branch) do
    {_output, status} = System.cmd("git", ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/" <> branch])
    status == 0
  end

  @spec log_record(String.t()) :: LogRecord.t()
  defp log_record(project_name) do
    %LogRecord{
      batch_id: "batch-run-x",
      run_id: "run-x",
      task_id: "1",
      project_name: project_name,
      adapter: Claude,
      state: :done,
      reason: :approved,
      verdict: :approve,
      duration_ms: 1
    }
  end

  @spec snapshot_env() :: map()
  defp snapshot_env do
    %{
      worktree: Application.get_env(:harness, :worktree),
      result_store: Application.get_env(:harness, :result_store),
      gh_cmd: Application.get_env(:harness, :gh_cmd),
      rmap_bin: Application.get_env(:harness, :rmap_bin),
      lander_target_sync: Application.get_env(:harness, :lander_target_sync),
      lander_resolver: Application.get_env(:harness, :lander_resolver)
    }
  end

  @spec restore_env(map()) :: :ok
  defp restore_env(previous) do
    Enum.each(previous, fn {key, value} -> restore(key, value) end)
  end

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
