defmodule Harness.Worktree.SweeperTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Worktree
  alias Harness.Worktree.Sweeper

  describe "sweep/1" do
    test "reaps an unmarked orphan, self-discovering its parent repo" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      {:ok, wt} = Worktree.create(repo, base_dir: base)

      assert {:ok, summary} = Sweeper.sweep(base)

      assert wt.path in summary.removed
      assert summary.kept == []
      assert summary.pruned == 1
      refute File.dir?(wt.path)
    end

    test "keeps a worktree carrying the retained marker" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      {:ok, wt} = Worktree.create(repo, base_dir: base)
      :ok = Worktree.finish(wt, :failure, retain_on_failure: true)

      assert {:ok, summary} = Sweeper.sweep(base)

      assert wt.path in summary.kept
      assert summary.removed == []
      assert File.dir?(wt.path)
    end

    test "leaves a directory with no parent repo in place" do
      base = GitFixture.tmp_base()
      partial = Path.join([base, "some-repo", "run-partial-create"])
      File.mkdir_p!(partial)

      assert {:ok, summary} = Sweeper.sweep(base)

      assert summary.removed == []
      assert summary.kept == []
      assert summary.pruned == 0
      assert File.dir?(partial)
    end

    test "returns an empty summary for an absent base dir" do
      base = GitFixture.tmp_base()

      assert {:ok, %{pruned: 0, removed: [], kept: []}} = Sweeper.sweep(base)
    end

    test "ignores worktrees outside the swept base dir" do
      repo = GitFixture.init_repo()
      outside = GitFixture.tmp_base(name: "outside")
      empty_base = GitFixture.tmp_base()
      {:ok, wt} = Worktree.create(repo, base_dir: outside)

      assert {:ok, %{removed: [], kept: []}} = Sweeper.sweep(empty_base)
      assert File.dir?(wt.path)
    end
  end

  describe "run/0" do
    test "sweeps the configured base dir and returns :ok" do
      assert :ok = Sweeper.run()
    end
  end

  describe "child_spec/1" do
    test "is a transient task child" do
      spec = Sweeper.child_spec([])

      assert spec.id == Sweeper
      assert spec.restart == :transient
      assert {Task, :start_link, [Sweeper, :run, []]} = spec.start
    end
  end
end
