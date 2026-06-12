defmodule Harness.RunDiffTest do
  # async: false because tests register projects in the singleton ProjectRegistry.
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.RunDiff

  # Carves a `harness/<run_id>` branch off the fixture repo's init commit with a
  # modified file (README.md) + an added file (lib.ex), then returns to main so
  # the diff is read against the fork point exactly as a settled run leaves it.
  defp repo_with_run(opts \\ []) do
    repo = GitFixture.init_repo()
    run_id = Keyword.get(opts, :run_id, "run-#{System.unique_integer([:positive])}")

    GitFixture.git!(repo, ["checkout", "-q", "-b", "harness/#{run_id}"])
    File.write!(Path.join(repo, "lib.ex"), "defmodule Lib do\n  def y, do: 2\nend\n")
    File.write!(Path.join(repo, "README.md"), "harness git fixture\nmore\n")
    GitFixture.git!(repo, ["add", "."])
    GitFixture.git!(repo, ["commit", "-q", "-m", "work"])
    GitFixture.git!(repo, ["checkout", "-q", "main"])

    {repo, run_id}
  end

  defp register(repo) do
    name = "rundiff-#{System.unique_integer([:positive])}"
    :ok = ProjectRegistry.register(ProjectFixture.from_repo(repo, name: name))
    on_exit(fn -> ProjectRegistry.unregister(name) end)
    name
  end

  describe "for_run/2" do
    test "returns the aggregate diff: file list, counts, classified lines" do
      {repo, run_id} = repo_with_run()
      name = register(repo)

      assert {:ok, diff} = RunDiff.for_run(run_id, name)
      assert diff.branch == "harness/#{run_id}"
      refute diff.truncated

      assert Enum.sort(Enum.map(diff.files, & &1.path)) == ["README.md", "lib.ex"]
      assert diff.added == Enum.reduce(diff.files, 0, &(&1.added + &2))
      assert diff.deleted == Enum.reduce(diff.files, 0, &(&1.deleted + &2))

      lib = Enum.find(diff.files, &(&1.path == "lib.ex"))
      assert lib.status == :added
      assert lib.added > 0
      assert Enum.any?(lib.lines, &(&1.kind == :add))
      assert Enum.any?(lib.lines, &(&1.kind == :hunk))

      readme = Enum.find(diff.files, &(&1.path == "README.md"))
      assert readme.status == :modified
    end

    test "no file's classified lines end with a stray blank context row" do
      {repo, run_id} = repo_with_run()
      name = register(repo)

      assert {:ok, diff} = RunDiff.for_run(run_id, name)

      # git's trailing newline must not surface as an empty :ctx line on the
      # last file (the String.split("\n") artifact).
      refute Enum.any?(diff.files, fn file ->
               match?(%{kind: :ctx, text: ""}, List.last(file.lines))
             end)
    end

    test "captures changes across multiple commits (repair attempts)" do
      {repo, run_id} = repo_with_run()

      # A second commit on the same branch, as a repair attempt would leave.
      GitFixture.git!(repo, ["checkout", "-q", "harness/#{run_id}"])
      File.write!(Path.join(repo, "extra.ex"), "defmodule Extra do\nend\n")
      GitFixture.git!(repo, ["add", "."])
      GitFixture.git!(repo, ["commit", "-q", "-m", "repair"])
      GitFixture.git!(repo, ["checkout", "-q", "main"])

      name = register(repo)

      assert {:ok, diff} = RunDiff.for_run(run_id, name)
      assert Enum.any?(diff.files, &(&1.path == "extra.ex"))
      assert Enum.any?(diff.files, &(&1.path == "lib.ex"))
    end

    test "returns :branch_absent when the run branch does not exist" do
      repo = GitFixture.init_repo()
      name = register(repo)
      assert {:error, :branch_absent} = RunDiff.for_run("never-ran-here", name)
    end

    test "returns :unknown_project for an unregistered name" do
      assert {:error, :unknown_project} = RunDiff.for_run("run-x", "no-such-project-xyz")
    end

    test "returns :unknown_project for a nil project name" do
      assert {:error, :unknown_project} = RunDiff.for_run("run-x", nil)
    end

    test "returns :repo_unavailable when the project's path is not a git tree" do
      dir = GitFixture.tmp_base()
      File.mkdir_p!(dir)

      name = "rundiff-nogit-#{System.unique_integer([:positive])}"
      :ok = ProjectRegistry.register(ProjectFixture.from_repo(dir, name: name))
      on_exit(fn -> ProjectRegistry.unregister(name) end)

      assert {:error, :repo_unavailable} = RunDiff.for_run("run-x", name)
    end
  end
end
