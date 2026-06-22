defmodule Harness.Git do
  @moduledoc """
  Internal: thin git subprocess wrapper shared by `Harness.Worktree` and its sweeper.

  git is always invoked with an argument list (never a shell string) and an
  explicit `-C <repo>`, so no path is ever interpolated into a shell.
  """

  @typedoc "A failed git invocation: the argv, the exit status, the combined output."
  @type error :: {:git_failed, args :: [String.t()], status :: integer(), output :: String.t()}

  @git_success_status 0

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

  @doc """
  Lists the paths with unresolved merge conflicts (`--diff-filter=U`) in `repo`.

  Used by the lander and its conflict resolver to enumerate the files a rebase
  left conflicted. Returns `{:error, {:conflict_list_failed, reason}}` on a failed
  git invocation.
  """
  @spec conflicted_files(String.t()) :: {:ok, [String.t()]} | {:error, {:conflict_list_failed, term()}}
  def conflicted_files(repo) do
    case run(["diff", "--name-only", "--diff-filter=U"], repo) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, reason} -> {:error, {:conflict_list_failed, reason}}
    end
  end

  @doc """
  Whether a failed `git push` of `pushed_ref` to `target` was rejected because it
  was **not a fast-forward** (the remote moved ahead under us), as opposed to any
  other push failure (auth, network, hook).

  Prefers a deterministic plumbing signal over git's English output: it first
  requires the failed push's non-zero `status`, force-refreshes the
  remote-tracking ref for `target`, then asks `git merge-base --is-ancestor
  <remote-tip> <pushed_ref>`. A non-fast-forward is exactly "the *current*
  remote tip is not an ancestor of what we pushed" — a fact independent of
  git's locale or release-specific phrasing.

  Falls back to matching git's rejection text (`non-fast-forward` / `fetch first`
  / `[rejected]`) only when the deterministic check is **inconclusive**: the
  remote ref can't be refreshed (offline, or the branch doesn't exist yet) or a
  ref won't resolve. `output` is the combined stdout+stderr of the failed push.
  """
  @spec non_fast_forward?(String.t(), String.t(), String.t(), integer(), String.t()) :: boolean()
  def non_fast_forward?(repo, pushed_ref, target, status, output) when status != @git_success_status do
    case remote_divergence(repo, pushed_ref, target) do
      :diverged -> true
      :fast_forwardable -> false
      :inconclusive -> rejected_text?(output)
    end
  end

  def non_fast_forward?(_repo, _pushed_ref, _target, _status, _output), do: false

  # The deterministic signal. `+` force-updates the tracking ref (a remote that
  # only moved forward is a fast-forward of it anyway; the prefix just keeps a
  # rewound remote from failing the fetch). Any failure — offline, missing
  # branch, unresolved ref — yields `:inconclusive` so the caller text-matches.
  @spec remote_divergence(String.t(), String.t(), String.t()) ::
          :diverged | :fast_forwardable | :inconclusive
  defp remote_divergence(repo, pushed_ref, target) do
    remote_ref = "refs/remotes/origin/" <> target

    with {:ok, _fetched} <- run(["fetch", "origin", "+#{target}:#{remote_ref}"], repo),
         {:ok, _remote} <- run(["rev-parse", "--verify", "--quiet", remote_ref <> "^{commit}"], repo),
         {:ok, _pushed} <- run(["rev-parse", "--verify", "--quiet", pushed_ref <> "^{commit}"], repo) do
      if ancestor?(repo, remote_ref, pushed_ref), do: :fast_forwardable, else: :diverged
    else
      _error -> :inconclusive
    end
  end

  # `merge-base --is-ancestor A B` exits 0 iff A is an ancestor of (or equal to) B.
  @spec ancestor?(String.t(), String.t(), String.t()) :: boolean()
  defp ancestor?(repo, maybe_ancestor, descendant) do
    match?({:ok, _output}, run(["merge-base", "--is-ancestor", maybe_ancestor, descendant], repo))
  end

  # Documented fallback only: git's English push-rejection phrasing is locale- and
  # version-fragile, so it is consulted solely when `remote_divergence/3` can't
  # decide deterministically.
  @spec rejected_text?(String.t()) :: boolean()
  defp rejected_text?(output) do
    String.contains?(output, "non-fast-forward") or
      String.contains?(output, "fetch first") or
      String.contains?(output, "[rejected]")
  end
end
