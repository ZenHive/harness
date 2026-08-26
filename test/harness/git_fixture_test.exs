defmodule Harness.GitFixtureTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.Worktree

  @moduletag :tmp_dir

  test "scratch repos live under the suite fixture root" do
    root = Application.fetch_env!(:harness, :test_fixture_root)
    repo = GitFixture.init_repo()
    assert String.starts_with?(repo, root)
  end

  test "checkout_existing without base_dir stays under the suite worktree root" do
    repo = GitFixture.init_repo(name: "repo")
    {:ok, wt} = Worktree.checkout_existing(repo, "main", id: "leak-probe")
    on_exit(fn -> _ = Worktree.remove(wt) end)

    suite_worktrees = Path.join(Application.fetch_env!(:harness, :test_fixture_root), "worktrees")
    assert String.starts_with?(wt.path, suite_worktrees)
    assert wt.path =~ "/harness-repo-"
    assert wt.path =~ "/landing/leak-probe"
    refute String.starts_with?(wt.path, Path.expand("~/_DATA/worktrees/.harness"))
  end

  test "suite cleanup removes landing leftovers after a successful run", %{tmp_dir: tmp_dir} do
    root = leak_tree(tmp_dir, "success")
    assert :ok = GitFixture.cleanup_suite_root(root, %{failures: 0})
    refute File.exists?(root)
  end

  test "suite cleanup removes landing leftovers after a failing run", %{tmp_dir: tmp_dir} do
    root = leak_tree(tmp_dir, "failure")
    assert :ok = GitFixture.cleanup_suite_root(root, %{failures: 1})
    refute File.exists?(root)
  end

  @spec leak_tree(String.t(), String.t()) :: String.t()
  defp leak_tree(tmp_dir, name) do
    root = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.join([root, "worktrees", "harness-repo-1", "landing"]))
    File.mkdir_p!(Path.join([root, "harness-suite-health-pass-1", "landing"]))
    root
  end
end
