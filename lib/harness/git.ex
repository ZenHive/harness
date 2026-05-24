defmodule Harness.Git do
  @moduledoc """
  Internal: thin git subprocess wrapper shared by `Harness.Worktree` and its sweeper.

  git is always invoked with an argument list (never a shell string) and an
  explicit `-C <repo>`, so no path is ever interpolated into a shell.
  """

  @typedoc "A failed git invocation: the argv, the exit status, the combined output."
  @type error :: {:git_failed, args :: [String.t()], status :: integer(), output :: String.t()}

  @doc """
  Runs `git -C <repo> <args...>`, capturing combined stdout + stderr.

  Returns `{:ok, output}` on exit 0, otherwise
  `{:error, {:git_failed, args, status, output}}`.
  """
  @spec run([String.t()], String.t()) :: {:ok, String.t()} | {:error, error()}
  def run(args, repo) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  @doc "Whether `repo` is inside a git working tree."
  @spec work_tree?(String.t()) :: boolean()
  def work_tree?(repo) do
    match?({:ok, _output}, run(["rev-parse", "--is-inside-work-tree"], repo))
  end
end
