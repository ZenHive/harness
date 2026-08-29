defmodule Harness.Git.TargetSync do
  @moduledoc """
  Fast-forwards a repo's *local* target branch to its freshly-pushed `origin`
  tip — ff-only, never forcing, never touching a dirty, non-ff, or self-host
  checkout.

  Both the autonomous lander (after it ff-pushes code) and durable roadmap
  writes (after they push a `roadmap: …` commit) push to `origin/<target>` but
  must then leave the operator's local `<target>` current. Skip it and the
  operator's next edit/commit/merge runs from a stale base — `roadmap/tasks.toml`
  drifts behind origin and a later merge conflicts or silently loses the harness
  transition (the exact failure that motivated making roadmap writes durable in
  the first place). This is the shared, notification-free core of that local
  sync; callers decide how to surface a `{:skipped, reason}` (the lander emits a
  witness event, durable writes log). `ensure_current/2` is the read-side
  companion: it fetches `origin/<target>` and reports whether HEAD is behind,
  without merging, fast-forwarding, or otherwise writing the working tree.
  Callers that would *read* a checkout this module could not refresh (the cron
  poller) use it to refuse rather than consume a stale `tasks.toml`.

  Mechanical only — four cases:

    * operator off `<target>` → ff the local branch ref (working tree untouched),
    * operator on `<target>` with a clean tree → `merge --ff-only`,
    * operator on `<target>` with a dirty tree, or a non-ff local divergence →
      `{:skipped, reason}`; the operator syncs manually,
    * `repo` *is* this running node's source tree (self-host, path identity, not
      the registered project name) → `{:skipped, reason}` naming that case, so a
      self-land cannot mutate the checkout the node is executing from.
  """

  alias Harness.Git

  @typedoc "The outcome of a local fast-forward attempt."
  @type result :: :synced | {:skipped, String.t()}

  @typedoc "Whether a local checkout is safe to use as a read source for a remote target."
  @type currency_result :: :current | {:error, term()}

  @doc """
  Fetches `origin/<target>` and verifies that HEAD is not behind it.

  Returns `:current` when the checkout has every commit on `origin/<target>`
  (local-ahead is allowed). Returns `{:error, {:checkout_behind, target, n}}`
  when it does not, or `{:error, {:currency_check_failed, reason}}` when
  currency cannot be proven (fetch failed, unexpected `rev-list` output).

  Never `--force`, never merges, never touches the working tree — a dirty or
  self-host checkout is left exactly as found.
  """
  @spec ensure_current(String.t(), String.t()) :: currency_result()
  def ensure_current(repo, target) when is_binary(repo) and is_binary(target) do
    with :ok <- fetch_remote_target(repo, target),
         {:ok, counts} <- Git.run(["rev-list", "--left-right", "--count", "HEAD...origin/" <> target], repo),
         {:ok, behind} <- parse_behind_count(counts) do
      if behind == 0, do: :current, else: {:error, {:checkout_behind, target, behind}}
    else
      {:error, reason} -> {:error, {:currency_check_failed, reason}}
    end
  end

  @doc """
  Fast-forwards `repo`'s local `target` branch to `origin/<target>`.

  Returns `:synced` when the local branch (or checked-out working tree) was
  advanced, or `{:skipped, reason}` when it was deliberately left alone — a dirty
  checked-out tree, a non-ff local divergence, a self-host checkout, or a git
  step that failed. The reason is a human-readable string (`"local <target>
  behind origin by N; sync manually"`, prefixed `self-host: ` for the self-host
  skip); a caller surfaces it however it likes. Never `--force`, never touches a
  dirty or self-host working tree.
  """
  @spec ff_local(String.t(), String.t()) :: result()
  def ff_local(repo, target) when is_binary(repo) and is_binary(target) do
    with :ok <- fetch_remote_target(repo, target),
         :ok <- reject_self_host(repo, target),
         {:ok, branch} <- current_branch(repo) do
      if branch == target,
        do: sync_checked_out(repo, target),
        else: sync_unchecked_out(repo, target)
    else
      {:skipped, _reason} = skipped -> skipped
      {:error, reason} -> {:skipped, "local #{target} sync skipped: #{inspect(reason)}; sync manually"}
    end
  end

  @spec fetch_remote_target(String.t(), String.t()) :: :ok | {:error, term()}
  defp fetch_remote_target(repo, target) do
    refspec = "refs/heads/#{target}:refs/remotes/origin/#{target}"

    case Git.run(["fetch", "origin", refspec], repo) do
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
    refspec = "refs/heads/#{target}:refs/heads/#{target}"

    case Git.run(["fetch", "origin", refspec], repo) do
      {:ok, _output} -> :synced
      {:error, _reason} -> {:skipped, drift_message(repo, target)}
    end
  end

  # Path identity against the running node's source tree (Mix project root, else
  # cwd) — a renamed clone and a renamed registered project both still trip.
  @spec reject_self_host(String.t(), String.t()) :: :ok | {:skipped, String.t()}
  defp reject_self_host(repo, target) do
    if same_tree?(Path.expand(repo), Path.expand(node_source_root())) do
      {:skipped, "self-host: " <> drift_message(repo, target)}
    else
      :ok
    end
  end

  @spec node_source_root() :: String.t()
  defp node_source_root do
    case Application.get_env(:harness, :node_source_root) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        if Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :project_file, 0) and Mix.Project.get() do
          Mix.Project.project_file() |> Path.expand() |> Path.dirname()
        else
          File.cwd!()
        end
    end
  end

  @spec same_tree?(String.t(), String.t()) :: boolean()
  defp same_tree?(left, right) do
    left == right or
      match?(
        {{:ok, %{major_device: device, inode: inode}}, {:ok, %{major_device: device, inode: inode}}},
        {File.stat(left), File.stat(right)}
      )
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

  @spec parse_behind_count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp parse_behind_count(output) do
    case output |> String.split() |> Enum.map(&Integer.parse/1) do
      [{_ahead, ""}, {behind, ""}] when behind >= 0 -> {:ok, behind}
      _ -> {:error, {:unexpected_rev_list_output, output}}
    end
  end
end
