defmodule Harness.AgentAdapter.Testing.GitFixture do
  @moduledoc """
  Throwaway git repositories and isolated working roots for adapter tests.

  Ships in `lib/` rather than `test/support/` because
  `Harness.AgentAdapter.Testing.ConformanceCase` calls `init_repo/1` for its
  live end-to-end case: a consumer that `use`s the conformance suite against
  its own adapter compiles only this package's `lib/`, so a fixture left behind
  in `test/support/` would raise `UndefinedFunctionError` at run time.

  An adapter is handed a `cwd` and is expected to confine its writes to it, so
  most adapter tests need a real repository rather than a bare directory:
  several agent CLIs behave differently outside a git worktree.

  Every path handed out is created under `System.tmp_dir!/0` with a
  collision-proof suffix and registered for `ExUnit.Callbacks.on_exit/1`
  cleanup. The `File.rm_rf/1` calls therefore only ever delete these tmp
  fixtures — test scaffolding cleaning up after itself, never a real target
  repository.

  Requires a running ExUnit test process (for the cleanup hook) and `git` on
  `PATH`.
  """

  @doc """
  Creates a tmp git repository with one commit on `main` and returns its path.

  Identity is configured locally so the commit succeeds on a host with no
  global git identity. Pass `:name` to label the tmp directory; it is a
  readability aid only, uniqueness comes from the generated suffix.
  """
  @spec init_repo(keyword()) :: String.t()
  # sobelow_skip ["Traversal.FileModule"]
  def init_repo(opts \\ []) do
    repo = unique_tmp_dir(Keyword.get(opts, :name, "repo"))
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "--initial-branch=main"])
    git!(repo, ["config", "user.email", "harness-test@example.com"])
    git!(repo, ["config", "user.name", "Harness Test"])
    File.write!(Path.join(repo, "README.md"), "harness git fixture\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-q", "-m", "init"])
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  @doc """
  Creates a bare `origin` plus a working clone already pushed to `origin/main`,
  returning `%{origin: path, repo: path}`.

  Use it when the behaviour under test pushes or fetches: with a real remote
  the push is genuine and assertable instead of stubbed out. Per-test branch
  and commit setup stays in the test.
  """
  @spec init_with_origin(keyword()) :: %{origin: String.t(), repo: String.t()}
  def init_with_origin(opts \\ []) do
    name = Keyword.get(opts, :name, "repo")
    origin = init_bare(name)
    repo = init_repo(name: name)
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "-q", "-u", "origin", "main"])
    %{origin: origin, repo: repo}
  end

  @doc """
  Reserves a unique tmp path, registers it for cleanup, and returns it.

  The path is **not** created — that is deliberate, so the caller (or a tool
  like `git worktree add`, which insists on a fresh destination) can create it
  itself. The non-git counterpart to `init_repo/1`, for a test needing an
  isolated scratch root without the cost of a repository.
  """
  @spec tmp_base(keyword()) :: String.t()
  # sobelow_skip ["Traversal.FileModule"]
  def tmp_base(opts \\ []) do
    base = unique_tmp_dir(Keyword.get(opts, :name, "base"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(base) end)
    base
  end

  @doc """
  Runs `git -C repo <args>`, returning its combined output or raising on a
  non-zero exit.

  Fixture setup has no meaningful recovery from a failed git command, so this
  raises with the command and its output rather than returning an error tuple
  a caller would only re-raise.
  """
  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}):\n#{output}"
    end
  end

  # `git init --bare` creates the directory itself, so this cannot go through
  # `git!/2` (whose `-C <repo>` requires an existing directory).
  @spec init_bare(String.t()) :: String.t()
  # sobelow_skip ["Traversal.FileModule"]
  defp init_bare(name) do
    origin = unique_tmp_dir("#{name}-origin")

    case System.cmd("git", ["init", "-q", "--bare", "--initial-branch=main", origin], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "git init --bare failed (#{status}):\n#{output}"
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(origin) end)
    origin
  end

  @spec unique_tmp_dir(String.t()) :: String.t()
  defp unique_tmp_dir(name) do
    # Wall-clock nanoseconds keep the path unique across BEAM restarts, where
    # `System.unique_integer/1` resets to 1 and would otherwise collide with a
    # crashed previous run's leftovers in `/tmp` — the original flaky-fixture
    # failure mode ("nothing to commit, working tree clean" because the prior
    # run's README.md was already committed at the same path).
    suffix = "#{System.unique_integer([:positive])}-#{System.os_time(:nanosecond)}"
    Path.join(System.tmp_dir!(), "harness-#{name}-#{suffix}")
  end
end
