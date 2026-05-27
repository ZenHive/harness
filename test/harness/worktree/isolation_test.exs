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

  describe "default_pollution_allowlist/0" do
    test "covers Claude Code session state and common editor noise" do
      allowlist = Isolation.default_pollution_allowlist()

      assert ".claude/" in allowlist
      assert ".DS_Store" in allowlist
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

    test "ignores incidental Claude Code session state under .claude/" do
      repo = GitFixture.init_repo()
      assert {:ok, before} = Isolation.snapshot(repo)

      claude_dir = Path.join(repo, ".claude")
      File.mkdir_p!(claude_dir)
      File.write!(Path.join(claude_dir, "scheduled_tasks.lock"), "wakeup\n")

      assert :ok = Isolation.check_pollution(repo, before)
    end

    test "ignores editor lockfiles and .DS_Store" do
      repo = GitFixture.init_repo()
      assert {:ok, before} = Isolation.snapshot(repo)

      File.write!(Path.join(repo, ".DS_Store"), "")
      File.write!(Path.join(repo, "README.md~"), "backup\n")

      assert :ok = Isolation.check_pollution(repo, before)
    end

    test "still detects pollution under lib/" do
      repo = GitFixture.init_repo()
      assert {:ok, before} = Isolation.snapshot(repo)

      lib_dir = Path.join(repo, "lib")
      File.mkdir_p!(lib_dir)
      File.write!(Path.join(lib_dir, "foo.ex"), "defmodule Foo, do: nil\n")

      assert {:error, {:checkout_polluted, diff}} = Isolation.check_pollution(repo, before)
      assert diff =~ "lib/"
    end

    test "detects lib pollution even when allowlisted paths also changed" do
      repo = GitFixture.init_repo()
      assert {:ok, before} = Isolation.snapshot(repo)

      claude_dir = Path.join(repo, ".claude")
      File.mkdir_p!(claude_dir)
      File.write!(Path.join(claude_dir, "scheduled_tasks.lock"), "wakeup\n")

      lib_dir = Path.join(repo, "lib")
      File.mkdir_p!(lib_dir)
      File.write!(Path.join(lib_dir, "leaked.ex"), "pollution\n")

      assert {:error, {:checkout_polluted, diff}} = Isolation.check_pollution(repo, before)
      assert diff =~ "lib/"
      refute diff =~ ".claude"
    end

    test "accepts a custom per-check allowlist override" do
      repo = GitFixture.init_repo()
      assert {:ok, before} = Isolation.snapshot(repo)

      File.write!(Path.join(repo, "scratch.txt"), "benign\n")

      assert :ok =
               Isolation.check_pollution(repo, before, pollution_allowlist: ["scratch.txt"])
    end
  end
end
