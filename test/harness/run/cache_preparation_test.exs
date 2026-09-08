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

  test "preparation precedes agent dispatch and reviewer remains mandatory" do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, ".gitignore"), "prepared/\n")
    GitFixture.git!(repo, ["add", ".gitignore"])
    GitFixture.git!(repo, ["commit", "-qm", "ignore cache outputs"])
    base = GitFixture.tmp_base()

    recipe = %{
      "commands" => ["mkdir -p prepared; printf bytes > prepared/value"],
      "paths" => ["prepared"],
      "identity_commands" => ["printf tool"]
    }

    project = %{ProjectFixture.from_repo(repo) | cache_preparation: recipe}

    opts =
      base
      |> default_opts()
      |> Keyword.put(:retain_on_failure, true)
      |> Keyword.put(:reviewer_adapter_opts, command: {:review, "reject"})

    {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)
    assert %Result{state: :failed} = result = await_result(run_id, pid)
    assert File.read!(Path.join(result.worktree_path, "prepared/value")) == "bytes"
    assert File.exists?(Path.join(result.worktree_path, ".harness/review.json"))
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
