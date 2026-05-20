defmodule Harness.GitFixture do
  @moduledoc false

  # Test scaffolding for the worktree suite: spins up throwaway git repositories
  # and isolated worktree roots in the system tmp dir, each registered for
  # `on_exit` cleanup. `File.rm_rf/1` here deletes only these tmp fixtures —
  # test scaffolding cleaning up after itself, never a real target repo.

  @spec init_repo(keyword()) :: String.t()
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

  @spec tmp_base(keyword()) :: String.t()
  def tmp_base(opts \\ []) do
    base = unique_tmp_dir(Keyword.get(opts, :name, "base"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(base) end)
    base
  end

  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}):\n#{output}"
    end
  end

  @spec unique_tmp_dir(String.t()) :: String.t()
  defp unique_tmp_dir(name) do
    Path.join(System.tmp_dir!(), "harness-#{name}-#{System.unique_integer([:positive])}")
  end
end
