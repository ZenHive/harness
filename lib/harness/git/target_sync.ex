defmodule Harness.Git.TargetSync do
  @moduledoc """
  Fast-forwards a repo's *local* target branch to its freshly-pushed `origin`
  tip — ff-only, never forcing, never touching a dirty or non-ff checkout.

  Both the autonomous lander (after it ff-pushes code) and durable roadmap
  writes (after they push a `roadmap: …` commit) push to `origin/<target>` but
  must then leave the operator's local `<target>` current. Skip it and the
  operator's next edit/commit/merge runs from a stale base — `roadmap/tasks.toml`
  drifts behind origin and a later merge conflicts or silently loses the harness
  transition (the exact failure that motivated making roadmap writes durable in
  the first place). This is the shared, notification-free core of that local
  sync; callers decide how to surface a `{:skipped, reason}` (the lander emits a
  witness event, durable writes log).

  Mechanical only — three cases:

    * operator off `<target>` → ff the local branch ref (working tree untouched),
    * operator on `<target>` with a clean tree → `merge --ff-only`,
    * operator on `<target>` with a dirty tree, or a non-ff local divergence →
      `{:skipped, reason}`; the operator syncs manually.
  """

  alias Harness.Git

  @typedoc "The outcome of a local fast-forward attempt."
  @type result :: :synced | {:skipped, String.t()}

  @doc """
  Fast-forwards `repo`'s local `target` branch to `origin/<target>`.

  Returns `:synced` when the local branch (or checked-out working tree) was
  advanced, or `{:skipped, reason}` when it was deliberately left alone — a dirty
  checked-out tree, a non-ff local divergence, or a git step that failed. The
  reason is a human-readable string (`"local <target> behind origin by N; sync
  manually"`); a caller surfaces it however it likes. Never `--force`, never
  touches a dirty working tree.
  """
  @spec ff_local(String.t(), String.t()) :: result()
  def ff_local(repo, target) when is_binary(repo) and is_binary(target) do
    with :ok <- fetch_remote_target(repo, target),
         {:ok, branch} <- current_branch(repo) do
      if branch == target,
        do: sync_checked_out(repo, target),
        else: sync_unchecked_out(repo, target)
    else
      {:error, reason} ->
        {:skipped, "local #{target} sync skipped: #{inspect(reason)}; sync manually"}
    end
  end

  @spec fetch_remote_target(String.t(), String.t()) :: :ok | {:error, term()}
  defp fetch_remote_target(repo, target) do
    case Git.run(["fetch", "origin", "#{target}:refs/remotes/origin/#{target}"], repo) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:fetch_remote_target_failed, reason}}
    end
  end

  @spec current_branch(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp current_branch(repo) do
    case Git.run(["branch", "--show-current"], repo) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:current_branch_failed, reason}}
    end
  end

  @spec sync_checked_out(String.t(), String.t()) :: result()
  defp sync_checked_out(repo, target) do
    if clean_worktree?(repo), do: merge_ff(repo, target), else: {:skipped, drift_message(repo, target)}
  end

  @spec clean_worktree?(String.t()) :: boolean()
  defp clean_worktree?(repo) do
    match?({:ok, ""}, Git.run(["status", "--porcelain"], repo))
  end

  @spec merge_ff(String.t(), String.t()) :: result()
  defp merge_ff(repo, target) do
    case Git.run(["merge", "--ff-only", "origin/" <> target], repo) do
      {:ok, _output} -> :synced
      {:error, _reason} -> {:skipped, drift_message(repo, target)}
    end
  end

  # Operator isn't on the target, so updating the local branch ref via fetch is a
  # pure ref move — no working-tree change. fetch refuses a non-ff branch update,
  # so a diverged local branch surfaces as a skip rather than a clobber.
  @spec sync_unchecked_out(String.t(), String.t()) :: result()
  defp sync_unchecked_out(repo, target) do
    case Git.run(["fetch", "origin", "#{target}:#{target}"], repo) do
      {:ok, _output} -> :synced
      {:error, _reason} -> {:skipped, drift_message(repo, target)}
    end
  end

  @spec drift_message(String.t(), String.t()) :: String.t()
  defp drift_message(repo, target) do
    "local #{target} behind origin by #{behind_count(repo, target)}; sync manually"
  end

  @spec behind_count(String.t(), String.t()) :: non_neg_integer() | String.t()
  defp behind_count(repo, target) do
    case Git.run(["rev-list", "--count", "#{target}..origin/#{target}"], repo) do
      {:ok, output} -> output |> String.trim() |> String.to_integer()
      {:error, _reason} -> "unknown"
    end
  end
end
