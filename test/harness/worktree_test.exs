defmodule Harness.WorktreeTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Invocation
  alias Harness.GitFixture
  alias Harness.Worktree

  describe "create/2" do
    test "carves an isolated worktree and branch off HEAD" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      assert {:ok, %Worktree{} = wt} = Worktree.create(repo, base_dir: base)

      assert String.starts_with?(wt.id, "run-")
      assert wt.branch == "harness/" <> wt.id
      assert wt.repo == Path.expand(repo)
      assert wt.path == Path.join([base, Path.basename(repo), wt.id])
      assert File.dir?(wt.path)
      assert File.exists?(Path.join(wt.path, ".git"))
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
      assert GitFixture.git!(repo, ["worktree", "list"]) =~ wt.path
    end

    test "honors the :base_ref option" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      GitFixture.git!(repo, ["checkout", "-q", "-b", "feature"])
      GitFixture.git!(repo, ["commit", "--allow-empty", "-q", "-m", "feature work"])
      GitFixture.git!(repo, ["checkout", "-q", "main"])
      feature_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "feature"]))

      assert {:ok, wt} = Worktree.create(repo, base_dir: base, base_ref: "feature")

      assert String.trim(GitFixture.git!(wt.path, ["rev-parse", "HEAD"])) == feature_sha
      assert wt.base_sha == feature_sha
    end

    test "captures the resolved base SHA on the worktree handle" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      head_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))

      assert {:ok, wt} = Worktree.create(repo, base_dir: base)

      assert wt.base_sha == head_sha
    end

    test "honors the :id option" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      assert {:ok, wt} = Worktree.create(repo, base_dir: base, id: "run-fixed-id")

      assert wt.id == "run-fixed-id"
      assert wt.branch == "harness/run-fixed-id"
    end

    test "rejects a path that is not a git repository" do
      base = GitFixture.tmp_base()
      plain = GitFixture.tmp_base(name: "plain")
      File.mkdir_p!(plain)

      assert {:error, {:not_a_git_repo, ^plain}} = Worktree.create(plain, base_dir: base)
    end

    test "rejects a path that does not exist" do
      base = GitFixture.tmp_base()
      missing = Path.join(System.tmp_dir!(), "harness-missing-#{System.unique_integer([:positive])}")

      assert {:error, {:repo_not_found, expanded}} = Worktree.create(missing, base_dir: base)
      assert expanded == Path.expand(missing)
    end

    test "concurrent creates on one repo never collide" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      worktrees =
        1..8
        |> Task.async_stream(fn _ -> Worktree.create(repo, base_dir: base) end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, {:ok, wt}} -> wt end)

      assert length(worktrees) == 8
      assert worktrees |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 8
      assert worktrees |> Enum.map(& &1.path) |> Enum.uniq() |> length() == 8
      assert worktrees |> Enum.map(& &1.branch) |> Enum.uniq() |> length() == 8
      assert Enum.all?(worktrees, &File.dir?(&1.path))
    end
  end

  describe "commit/2" do
    test "commits the worktree's changes onto its branch" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["show", "#{wt.branch}:delivery.txt"]) == "agent work\n"
      assert GitFixture.git!(repo, ["log", "-1", "--format=%s", wt.branch]) =~ "agent delivery"
    end

    test "stamps an explicit harness committer identity" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["log", "-1", "--format=%an <%ae>", wt.branch]) =~
               "harness <harness@localhost>"
    end

    test "reports :no_changes and commits nothing on a clean worktree" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "reports :no_changes after Claude injects rules into a no-op run" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"claude", _argv, _env}} = Claude.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "reports :no_changes after Codex injects rules into a no-op run" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"codex", _argv, _env}} = Codex.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "reports :no_changes after Cursor injects rules into a no-op run" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"cursor-agent", _argv, _env}} = Cursor.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "does not commit Codex's harness block into an existing AGENTS.md" do
      repo = GitFixture.init_repo()
      File.write!(Path.join(repo, "AGENTS.md"), "target repo instructions\n")
      GitFixture.git!(repo, ["add", "AGENTS.md"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "add agents"])
      base = GitFixture.tmp_base()
      {:ok, wt} = Worktree.create(repo, base_dir: base)
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"codex", _argv, _env}} = Codex.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
      assert File.read!(Path.join(wt.path, "AGENTS.md")) == "target repo instructions\n"
    end

    test "commits legitimate Codex edits to AGENTS.md without the harness block" do
      {repo, wt} = create_worktree()

      assert {:ok, {"codex", _argv, _env}} = Codex.build_command(invocation(wt.path))
      agents = Path.join(wt.path, "AGENTS.md")
      File.write!(agents, File.read!(agents) <> "\nproject rules\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["show", "#{wt.branch}:AGENTS.md"]) == "project rules\n"
    end

    test "surfaces a git failure on a path that is not a git repository" do
      plain = GitFixture.tmp_base(name: "plain")
      File.mkdir_p!(plain)

      bogus = %Worktree{
        id: "run-x",
        path: plain,
        branch: "harness/run-x",
        repo: plain,
        base_sha: "0000000000000000000000000000000000000000"
      }

      assert {:error, {:git_failed, _args, status, _output}} = Worktree.commit(bogus, "agent delivery")
      assert status != 0
    end

    test "refuses to commit when the agent detached HEAD off the run branch" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      branch_sha_before = String.trim(GitFixture.git!(repo, ["rev-parse", wt.branch]))
      GitFixture.git!(wt.path, ["checkout", "-q", "--detach"])
      head_sha = String.trim(GitFixture.git!(wt.path, ["rev-parse", "HEAD"]))

      assert {:error, {:head_moved, expected, {:detached, ^head_sha}}} =
               Worktree.commit(wt, "agent delivery")

      assert expected == wt.branch
      # Deliverable is not stranded: the run branch is unchanged, and the
      # agent's work still lives in the worktree's working tree.
      assert String.trim(GitFixture.git!(repo, ["rev-parse", wt.branch])) == branch_sha_before
      assert File.read!(Path.join(wt.path, "delivery.txt")) == "agent work\n"
    end

    test "refuses to commit when the agent switched HEAD to a different branch" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      branch_sha_before = String.trim(GitFixture.git!(repo, ["rev-parse", wt.branch]))
      GitFixture.git!(wt.path, ["checkout", "-q", "-b", "agent-detour"])

      assert {:error, {:head_moved, expected, {:branch, "agent-detour"}}} =
               Worktree.commit(wt, "agent delivery")

      assert expected == wt.branch
      assert String.trim(GitFixture.git!(repo, ["rev-parse", wt.branch])) == branch_sha_before
      assert File.read!(Path.join(wt.path, "delivery.txt")) == "agent work\n"
    end
  end

  describe "finish/3" do
    test "tears the worktree down on :success, keeping the branch" do
      {repo, wt} = create_worktree()

      assert :ok = Worktree.finish(wt, :success)

      refute File.dir?(wt.path)
      refute GitFixture.git!(repo, ["worktree", "list"]) =~ wt.path
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
    end

    test "retains the worktree on :failure by default, dropping a marker" do
      {_repo, wt} = create_worktree()

      assert :ok = Worktree.finish(wt, :failure)

      assert File.dir?(wt.path)
      assert Worktree.retained?(wt.path)
      assert File.read!(Path.join(wt.path, ".harness-retained")) =~ "branch=#{wt.branch}"
    end

    test "tears down on :failure when retain_on_failure is false" do
      {_repo, wt} = create_worktree()

      assert :ok = Worktree.finish(wt, :failure, retain_on_failure: false)

      refute File.dir?(wt.path)
    end

    test "surfaces a marker write failure when the worktree path is gone" do
      {_repo, wt} = create_worktree()
      :ok = Worktree.remove(wt)

      assert {:error, {:marker_write_failed, marker, :enoent}} =
               Worktree.finish(wt, :failure)

      assert marker == Path.join(wt.path, ".harness-retained")
    end
  end

  describe "remove/1" do
    test "removes the worktree directory" do
      {_repo, wt} = create_worktree()

      assert :ok = Worktree.remove(wt)
      refute File.dir?(wt.path)
    end

    test "a second remove surfaces the git failure rather than swallowing it" do
      {_repo, wt} = create_worktree()
      assert :ok = Worktree.remove(wt)

      assert {:error, {:git_failed, _args, status, _output}} = Worktree.remove(wt)
      assert status != 0
    end
  end

  describe "retained?/1" do
    test "is false for a fresh worktree, true once retained" do
      {_repo, wt} = create_worktree()
      refute Worktree.retained?(wt.path)

      assert :ok = Worktree.finish(wt, :failure)
      assert Worktree.retained?(wt.path)
    end
  end

  describe "base_dir/1" do
    test "the :base_dir option overrides the configured fallback" do
      assert Worktree.base_dir(base_dir: "/tmp/explicit") == "/tmp/explicit"
    end

    test "falls back to configuration when no option is given" do
      assert Worktree.base_dir() == Application.get_env(:harness, :worktree)[:base_dir]
    end
  end

  defp create_worktree do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    {:ok, wt} = Worktree.create(repo, base_dir: base)
    {repo, wt}
  end

  defp invocation(cwd) do
    %Invocation{prompt: "do nothing", cwd: cwd, task_id: "36"}
  end
end
