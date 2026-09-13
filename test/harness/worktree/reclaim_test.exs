defmodule Harness.Worktree.ReclaimTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Worktree
  alias Harness.Worktree.Reclaim

  describe "run/1 dry-run" do
    test "reports only landed branches whose commits are on the target" do
      {repo, base, project, landed, unlanded} = fixture_pair()

      {:ok, report} = Reclaim.run(dry_run: true, base_dir: base, projects: [project])

      assert report.dry_run
      by_id = Map.new(report.items, &{&1.run_id, &1})
      assert by_id[landed.id].action == :reclaim
      assert by_id[landed.id].reason == :reachable
      assert by_id[unlanded.id].action == :retain
      assert by_id[unlanded.id].reason == :sole_copy
      assert File.dir?(landed.path)
      assert File.dir?(unlanded.path)
      assert branch_exists?(repo, landed.branch)
      assert branch_exists?(repo, unlanded.branch)
    end

    test "retains live, retained, and held sole-copy leftovers" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo, target_branch: "main")
      {:ok, live} = Worktree.create(project, base_dir: base, id: "live-run")
      commit_unique(live, "live")
      {:ok, failed} = Worktree.create(project, base_dir: base, id: "failed-run")
      commit_unique(failed, "failed")
      :ok = Worktree.finish(failed, :failure)

      parent = self()

      holder =
        spawn(fn ->
          {:ok, _} = Registry.register(Harness.Run.Registry, live.id, nil)
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(holder, :kill) end)

      {:ok, report} = Reclaim.run(dry_run: true, base_dir: base, projects: [project])
      by_id = Map.new(report.items, &{&1.run_id, &1})

      assert by_id[live.id].action == :retain
      assert by_id[live.id].reason == :live_run
      assert by_id[failed.id].action == :retain
      assert by_id[failed.id].reason == :retained
    end
  end

  describe "run/1 apply" do
    test "reclaims landed leftovers and leaves sole copies" do
      {repo, base, project, landed, unlanded} = fixture_pair()

      {:ok, report} = Reclaim.run(dry_run: false, base_dir: base, projects: [project])

      refute report.dry_run
      refute File.dir?(landed.path)
      refute branch_exists?(repo, landed.branch)
      assert File.dir?(unlanded.path)
      assert branch_exists?(repo, unlanded.branch)
      assert Enum.any?(report.applied, &(&1.run_id == landed.id and &1.action == :reclaim))
      refute Enum.any?(report.applied, &(&1.run_id == unlanded.id))
    end
  end

  describe "filesystem orphans" do
    test "detects an unregistered directory and reclaims it when the branch is landed" do
      {_repo, base, project, landed, _unlanded} = fixture_pair()
      gitdir = Path.join(landed.path, ".git")
      admin = git_admin_dir(landed.path)
      File.rm_rf!(admin)
      File.rm!(gitdir)

      {:ok, dry} = Reclaim.run(dry_run: true, base_dir: base, projects: [project])
      item = Enum.find(dry.items, &(&1.run_id == landed.id))
      assert item.action == :reclaim
      assert item.reason == :reachable
      assert item.path == landed.path

      {:ok, _applied} = Reclaim.run(dry_run: false, base_dir: base, projects: [project])
      refute File.dir?(landed.path)
    end

    test "distinguishes git-native repair from safe removal for a stale back-link" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo, target_branch: "main")
      {:ok, repairable} = Worktree.create(project, base_dir: base, id: "repair-me")
      commit_unique(repairable, "repair")
      {:ok, removable} = Worktree.create(project, base_dir: base, id: "remove-me")
      commit_unique(removable, "remove")
      GitFixture.git!(repo, ["merge", "--ff-only", removable.branch])

      stale_backlink(repairable)
      stale_backlink(removable)

      {:ok, report} = Reclaim.run(dry_run: true, base_dir: base, projects: [project])
      by_id = Map.new(report.items, &{&1.run_id, &1})

      assert by_id[repairable.id].action == :repair
      assert by_id[repairable.id].reason == :stale_backlink
      assert is_binary(by_id[repairable.id].backlink)
      refute File.exists?(by_id[repairable.id].backlink)

      assert by_id[removable.id].action == :reclaim
      assert by_id[removable.id].reason == :reachable

      {:ok, applied} = Reclaim.run(dry_run: false, base_dir: base, projects: [project])

      assert Enum.any?(applied.applied, &(&1.run_id == repairable.id and &1.action == :repair))
      assert File.dir?(repairable.path)
      assert File.exists?(gitdir_path(repairable.path))
      assert GitFixture.git!(repairable.path, ["status", "-sb"]) =~ repairable.branch

      refute File.dir?(removable.path)
      refute branch_exists?(repo, removable.branch)
    end
  end

  @spec fixture_pair() :: {String.t(), String.t(), Harness.Project.t(), Worktree.t(), Worktree.t()}
  defp fixture_pair do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    project = ProjectFixture.from_repo(repo, target_branch: "main")
    {:ok, landed} = Worktree.create(project, base_dir: base, id: "landed-run")
    commit_unique(landed, "landed")
    GitFixture.git!(repo, ["merge", "--ff-only", landed.branch])
    {:ok, unlanded} = Worktree.create(project, base_dir: base, id: "unlanded-run")
    commit_unique(unlanded, "unlanded")
    {repo, base, project, landed, unlanded}
  end

  @spec commit_unique(Worktree.t(), String.t()) :: :ok
  defp commit_unique(wt, label) do
    File.write!(Path.join(wt.path, "#{label}.txt"), "#{label}\n")
    GitFixture.git!(wt.path, ["add", "#{label}.txt"])
    GitFixture.git!(wt.path, ["commit", "-q", "-m", label])
    :ok
  end

  @spec stale_backlink(Worktree.t()) :: :ok
  defp stale_backlink(wt) do
    gitdir = gitdir_path(wt.path)
    id = Path.basename(gitdir)
    File.write!(Path.join(wt.path, ".git"), "gitdir: /nonexistent/.git/worktrees/#{id}\n")
    :ok
  end

  @spec gitdir_path(String.t()) :: String.t()
  defp gitdir_path(path) do
    "gitdir: " <> gitdir = path |> Path.join(".git") |> File.read!() |> String.trim()
    gitdir
  end

  @spec git_admin_dir(String.t()) :: String.t()
  defp git_admin_dir(path), do: gitdir_path(path)

  @spec branch_exists?(String.t(), String.t()) :: boolean()
  defp branch_exists?(repo, branch), do: GitFixture.git!(repo, ["branch", "--list", branch]) =~ branch
end
