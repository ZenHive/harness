defmodule Mix.Tasks.Harness.Worktree.ReclaimTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Worktree
  alias Mix.Tasks.Harness.Worktree.Reclaim

  test "run/1 dry-runs by default" do
    output = capture_io(fn -> assert :ok = Reclaim.run([]) end)

    assert output =~ "harness worktree reclaim (dry-run"
  end

  test "dry-run prints a completed empty scan" do
    repo = GitFixture.init_repo()
    project = ProjectFixture.from_repo(repo, name: "cli-empty", target_branch: "main")

    output =
      capture_io(fn ->
        assert :ok = Reclaim.emit(dry_run: true, base_dir: GitFixture.tmp_base(), projects: [project])
      end)

    assert output =~ "(dry-run, complete): 0 leftover(s)"
    assert output =~ "inspected: cli-empty repo=#{repo} target=main"
    refute output =~ "error:"
  end

  test "dry-run prints registry unavailability instead of an empty success" do
    pid = Process.whereis(Harness.ProjectRegistry)
    assert is_pid(pid)
    Process.unregister(Harness.ProjectRegistry)

    try do
      output =
        capture_io(fn ->
          assert :ok = Reclaim.emit(dry_run: true, base_dir: GitFixture.tmp_base())
        end)

      assert output =~ "(dry-run, incomplete)"
      assert output =~ "error: registry - :registry_unavailable"
      refute output =~ "(dry-run, complete): 0 leftover(s)"
    after
      Process.register(pid, Harness.ProjectRegistry)
    end
  end

  test "apply refuses a missing registry before any mutation" do
    pid = Process.whereis(Harness.ProjectRegistry)
    assert is_pid(pid)
    Process.unregister(Harness.ProjectRegistry)

    try do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/incomplete inspection; refusing apply/, fn ->
            Reclaim.emit(dry_run: false, base_dir: GitFixture.tmp_base())
          end
        end)

      assert output =~ "(apply, incomplete)"
      assert output =~ "error: registry - :registry_unavailable"
    after
      Process.register(pid, Harness.ProjectRegistry)
    end
  end

  test "dry-run prints an invalid repo as a repository error" do
    missing = Path.join(GitFixture.tmp_base(), "absent-repo")
    project = ProjectFixture.from_repo(missing, name: "cli-absent", target_branch: "main")

    output =
      capture_io(fn ->
        assert :ok = Reclaim.emit(dry_run: true, base_dir: GitFixture.tmp_base(), projects: [project])
      end)

    assert output =~ "(dry-run, incomplete)"
    assert output =~ "error: repository cli-absent :enoent"
  end

  test "dry-run prints an absent target as a target error" do
    repo = GitFixture.init_repo()
    project = ProjectFixture.from_repo(repo, name: "cli-no-target")

    output =
      capture_io(fn ->
        assert :ok = Reclaim.emit(dry_run: true, base_dir: GitFixture.tmp_base(), projects: [project])
      end)

    assert output =~ "(dry-run, incomplete)"
    assert output =~ "error: target cli-no-target :no_target_branch"
  end

  test "apply reports an unresolved target without deleting or repairing valid leftovers" do
    {repo, base, valid, landed, unlanded} = fixture_pair()
    backlink = "gitdir: /nonexistent/.git/worktrees/cli-unlanded\n"
    File.write!(Path.join(unlanded.path, ".git"), backlink)
    invalid = %{valid | name: "cli-bad-target", target_branch: "absent"}

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/incomplete inspection; refusing apply/, fn ->
          Reclaim.emit(dry_run: false, base_dir: base, projects: [valid, invalid])
        end
      end)

    assert output =~ "(apply, incomplete)"
    assert output =~ "error: target cli-bad-target"
    assert output =~ "unresolved_target"
    assert File.dir?(landed.path)
    assert branch_exists?(repo, landed.branch)
    assert File.read!(Path.join(unlanded.path, ".git")) == backlink
    assert branch_exists?(repo, unlanded.branch)
  end

  test "dry-run prints a git enumeration failure with bounded raw context" do
    plain = GitFixture.tmp_base(name: "cli-plain")
    File.mkdir_p!(plain)
    project = ProjectFixture.from_repo(plain, name: "cli-plain", target_branch: "main")

    output =
      capture_io(fn ->
        assert :ok = Reclaim.emit(dry_run: true, base_dir: GitFixture.tmp_base(), projects: [project])
      end)

    assert output =~ "(dry-run, incomplete)"
    assert output =~ "error: git cli-plain {:git_failed,"
    assert output =~ "for-each-ref"
  end

  test "incomplete apply prints mixed coverage and makes no mutations" do
    {repo, base, valid, landed, unlanded} = fixture_pair()
    missing = Path.join(GitFixture.tmp_base(), "gone")
    invalid = ProjectFixture.from_repo(missing, name: "cli-gone", target_branch: "main")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/incomplete inspection; refusing apply/, fn ->
          Reclaim.emit(dry_run: false, base_dir: base, projects: [valid, invalid])
        end
      end)

    assert output =~ "(apply, incomplete)"
    assert output =~ "inspected: #{valid.name}"
    assert output =~ "error: repository cli-gone :enoent"
    refute output =~ "applied:"
    assert File.dir?(landed.path)
    assert File.dir?(unlanded.path)
    assert branch_exists?(repo, landed.branch)
    assert branch_exists?(repo, unlanded.branch)
  end

  test "coverage lines bound long inspected, skipped, and error facts" do
    repo = GitFixture.init_repo()
    name = String.duplicate("long-name", 100)
    valid = ProjectFixture.from_repo(repo, name: name, target_branch: "main")
    skipped = %{valid | source: {:github, "https://github.com/example/demo.git"}}
    invalid = %{valid | target_branch: nil}

    output =
      capture_io(fn ->
        Reclaim.emit(base_dir: GitFixture.tmp_base(), projects: [valid, skipped, invalid])
      end)

    facts =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, ["inspected:", "skipped:", "error:"]))

    assert [_, _, _] = facts
    assert Enum.all?(facts, &(String.length(&1) <= 241))
    assert Enum.all?(facts, &String.ends_with?(&1, "…"))
  end

  @spec fixture_pair() :: {String.t(), String.t(), Harness.Project.t(), Worktree.t(), Worktree.t()}
  defp fixture_pair do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    project = ProjectFixture.from_repo(repo, target_branch: "main")
    {:ok, landed} = Worktree.create(project, base_dir: base, id: "cli-landed")
    commit_unique(landed, "landed")
    GitFixture.git!(repo, ["merge", "--ff-only", landed.branch])
    {:ok, unlanded} = Worktree.create(project, base_dir: base, id: "cli-unlanded")
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

  @spec branch_exists?(String.t(), String.t()) :: boolean()
  defp branch_exists?(repo, branch), do: GitFixture.git!(repo, ["branch", "--list", branch]) =~ branch
end
