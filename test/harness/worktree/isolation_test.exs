defmodule Harness.Worktree.IsolationTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Antigravity
  alias Harness.GitFixture
  alias Harness.Worktree.Isolation

  describe "validate/1" do
    test "accepts adapters that declare worktree isolation" do
      assert :ok = Isolation.validate(Harness.FakeAdapter)
    end

    test "rejects Antigravity before spawn" do
      assert {:error, {:worktree_isolation_unsupported, Antigravity, message}} =
               Isolation.validate(Antigravity)

      assert message =~ "agy ignores the port cwd"
    end
  end

  describe "check_pollution/2" do
    test "detects when the main checkout changed after the snapshot" do
      repo = GitFixture.init_repo()
      assert {:ok, before} = Isolation.snapshot(repo)

      File.write!(Path.join(repo, "leaked.txt"), "pollution\n")

      assert {:error, {:checkout_polluted, diff}} = Isolation.check_pollution(repo, before)
      assert diff =~ "leaked.txt"
    end

    test "returns :ok when the checkout is unchanged" do
      repo = GitFixture.init_repo()
      assert {:ok, before} = Isolation.snapshot(repo)
      assert :ok = Isolation.check_pollution(repo, before)
    end
  end
end
