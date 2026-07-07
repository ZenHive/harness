defmodule Harness.Worktree.IsolationTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Capabilities
  alias Harness.GitFixture
  alias Harness.Worktree.Isolation

  defmodule UnisolatedAdapter do
    @moduledoc false

    @spec capabilities() :: Capabilities.t()
    def capabilities, do: %Capabilities{worktree_isolation: false}

    @spec worktree_isolation_limitation() :: String.t()
    def worktree_isolation_limitation, do: "legacy cwd leak"
  end

  describe "validate/3" do
    test "accepts adapters that declare worktree isolation" do
      assert :ok = Isolation.validate(Harness.FakeAdapter, true, nil)
    end

    test "accepts Antigravity when worktree isolation is declared (cwd pinned via --add-dir in build_command/1)" do
      assert :ok = Isolation.validate(Antigravity, true, nil)
    end

    test "rejects unsupported adapters with the caller-provided limitation" do
      assert {:error, {:worktree_isolation_unsupported, UnisolatedAdapter, "legacy cwd leak"}} =
               Isolation.validate(
                 UnisolatedAdapter,
                 UnisolatedAdapter.capabilities().worktree_isolation,
                 UnisolatedAdapter.worktree_isolation_limitation()
               )
    end
  end

  describe "default_pollution_allowlist/0" do
    test "covers Claude Code session state and common editor noise" do
      allowlist = Isolation.default_pollution_allowlist()

      assert ".claude/" in allowlist
      assert "**/.DS_Store" in allowlist
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

    test "a path-anchored glob allowlist (`config/*.exs`) matches the full path, not just the basename" do
      repo = GitFixture.init_repo()
      # Track config/ first so git status reports the individual new file
      # (`?? config/dev.local.exs`) rather than collapsing the whole new dir to
      # `?? config/`.
      config_dir = Path.join(repo, "config")
      File.mkdir_p!(config_dir)
      File.write!(Path.join(config_dir, "config.exs"), "import Config\n")
      {_, 0} = System.cmd("git", ["add", "config/config.exs"], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-m", "add config/"], cd: repo)

      assert {:ok, before} = Isolation.snapshot(repo)

      File.write!(Path.join(config_dir, "dev.local.exs"), "import Config\n")

      assert :ok =
               Isolation.check_pollution(repo, before, pollution_allowlist: ["config/*.exs"])
    end

    test "REGRESSION (Task 69): rename out of a tracked dir flags pollution on the source path" do
      repo = GitFixture.init_repo()
      lib_dir = Path.join(repo, "lib")
      File.mkdir_p!(lib_dir)
      tracked = Path.join(lib_dir, "foo.ex")
      File.write!(tracked, "defmodule Foo, do: nil\n")
      {_, 0} = System.cmd("git", ["add", "lib/foo.ex"], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-m", "add lib/foo.ex"], cd: repo)

      assert {:ok, before} = Isolation.snapshot(repo)

      claude_dir = Path.join(repo, ".claude")
      File.mkdir_p!(claude_dir)
      File.rename!(tracked, Path.join(claude_dir, "foo.ex"))

      assert {:error, {:checkout_polluted, diff}} = Isolation.check_pollution(repo, before)
      assert diff =~ "lib/foo.ex"
    end

    test "REGRESSION (Task 69): default `.DS_Store` pattern matches at any depth" do
      repo = GitFixture.init_repo()
      docs_dir = Path.join(repo, "docs")
      File.mkdir_p!(docs_dir)
      File.write!(Path.join(docs_dir, "README.md"), "docs\n")
      {_, 0} = System.cmd("git", ["add", "docs/README.md"], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-m", "add docs/"], cd: repo)

      assert {:ok, before} = Isolation.snapshot(repo)

      File.write!(Path.join(docs_dir, ".DS_Store"), "")

      assert :ok = Isolation.check_pollution(repo, before)
    end
  end
end
