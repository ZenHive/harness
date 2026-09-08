defmodule Harness.Run.CachePreparationTest do
  use Harness.RunCase, async: false

  setup do
    prior = Application.get_env(:harness, :project_cache)
    root = GitFixture.tmp_base()
    Application.put_env(:harness, :project_cache, root: root)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:harness, :project_cache, prior),
        else: Application.delete_env(:harness, :project_cache)
    end)

    %{cache_root: root}
  end

  test "roadmap revisions share one preparation, isolated copies and mandatory review", %{cache_root: root} do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, ".gitignore"), "prepared/\n")
    GitFixture.git!(repo, ["add", ".gitignore"])
    GitFixture.git!(repo, ["commit", "-qm", "ignore cache outputs"])
    base = GitFixture.tmp_base()

    counter = Path.join(base, "build-count")
    File.mkdir_p!(base)

    recipe = %{
      "commands" => [~s(printf build >> "$COUNTER"; mkdir -p prepared; printf bytes > prepared/value)],
      "env" => %{"COUNTER" => counter},
      "exclude_inputs" => ["ROADMAP.md", "roadmap/data.json", "roadmap/tasks.toml"],
      "paths" => ["prepared"],
      "identity_commands" => ["printf tool"]
    }

    project = %{ProjectFixture.from_repo(repo) | cache_preparation: recipe}

    opts =
      base
      |> default_opts()
      |> Keyword.put(:retain_on_failure, true)
      |> Keyword.put(:reviewer_adapter_opts, command: {:review, "reject"})

    results =
      for revision <- ["one", "two"] do
        for path <- recipe["exclude_inputs"] do
          absolute = Path.join(repo, path)
          File.mkdir_p!(Path.dirname(absolute))
          File.write!(absolute, revision)
        end

        GitFixture.git!(repo, ["add", "--" | recipe["exclude_inputs"]])
        GitFixture.git!(repo, ["commit", "-qm", "roadmap revision"])
        {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)
        assert %Result{state: :failed, reason: {:review_rejected, _report}} = result = await_result(run_id, pid)
        assert File.read!(Path.join(result.worktree_path, "prepared/value")) == "bytes"
        assert File.exists?(Path.join(result.worktree_path, ".harness/review.json"))
        result
      end

    assert File.read!(counter) == "build"
    assert [generation] = Path.wildcard(Path.join(root, "*/prepared/value"))
    [first, second] = results
    refute first.worktree_path == second.worktree_path
    refute worktree_head(first.worktree_path) == worktree_head(second.worktree_path)
    File.write!(Path.join(first.worktree_path, "prepared/value"), "agent edit")
    assert File.read!(Path.join(second.worktree_path, "prepared/value")) == "bytes"
    assert File.read!(generation) == "bytes"
  end

  test "cancel remains responsive while preparation runs", %{cache_root: root} do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, ".gitignore"), "prepared/\n")
    GitFixture.git!(repo, ["add", ".gitignore"])
    GitFixture.git!(repo, ["commit", "-qm", "ignore cache outputs"])
    base = GitFixture.tmp_base()
    ready = Path.join(repo, "cache-ready")

    recipe = %{
      "commands" => ["mkdir -p prepared; printf started > \"$READY\"; sleep 30"],
      "paths" => ["prepared"],
      "identity_commands" => ["printf tool"],
      "env" => %{"READY" => ready}
    }

    project = %{ProjectFixture.from_repo(repo) | cache_preparation: recipe}
    {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, default_opts(base))
    await_file(ready)
    assert {:ok, %Status{state: :dispatched}} = Run.status(pid, 1000)
    assert :ok = Run.cancel(pid)
    assert %Result{state: :failed} = await_result(run_id, pid)
    assert Path.wildcard(Path.join(root, "*/complete.json")) == []
  end

  @spec worktree_head(String.t()) :: String.t()
  defp worktree_head(path) do
    {sha, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp await_file(path, attempts \\ 500)
  defp await_file(_path, 0), do: flunk("preparation did not start")

  defp await_file(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      receive do
      after
        10 -> await_file(path, attempts - 1)
      end
    end
  end
end
