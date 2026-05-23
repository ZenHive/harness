defmodule Harness.Worktree do
  @moduledoc """
  Per-run git worktree lifecycle.

  Every harness run executes inside its own git worktree: an isolated working
  directory and branch carved out of a target repository. Isolation means
  concurrent runs never collide on the working tree, and the verification stack
  always grades a clean checkout.

  ## Lifecycle

      {:ok, wt} = Harness.Worktree.create("/path/to/target/repo")
      # ... dispatch an agent with Invocation cwd: wt.path, let it work ...
      Harness.Worktree.commit(wt, "agent delivery")  # capture the work onto wt.branch
      Harness.Worktree.finish(wt, :success)   # verified green -> torn down
      Harness.Worktree.finish(wt, :failure)   # verified red  -> retained for inspection

  `create/2` carves the worktree, `commit/2` captures the agent's work as a
  commit on the worktree's branch, `finish/3` makes the keep-or-teardown
  decision, `remove/1` is the unconditional teardown. The worktree's `path` is
  what callers put in `Harness.AgentAdapter.Invocation`'s `cwd`.

  ## What it does not own

  Branch deletion and merge. `create/2` carves the `harness/<id>` branch and
  `commit/2` captures the agent's work onto it — those commits are the run's
  deliverable, so teardown removes only the working directory, never the branch.
  Deleting the branch or merging it back is the orchestrator's call. A crashed
  run that never reaches `finish/3` is reaped by the boot-time sweep in
  `Harness.Worktree.Sweeper`.

  ## Configuration

  Under the `:harness, :worktree` application key:

    * `:base_dir` — root the per-run worktrees are created under. Default
      `~/_DATA/worktrees/.harness`. Override per call with the `:base_dir`
      option, or globally with the `HARNESS_WORKTREE_ROOT` env var.
    * `:retain_on_failure` — whether `finish(wt, :failure)` keeps the worktree.
      Default `true`. Override per call with the `:retain_on_failure` option.
    * `:sweep_on_boot` — whether `Harness.Application` runs the boot-time
      orphan sweep (`Harness.Worktree.Sweeper`) at application start.
      Default `true`.
  """

  alias Harness.Git

  @branch_prefix "harness/"
  @retained_marker ".harness-retained"
  @default_base_dir "~/_DATA/worktrees/.harness"

  # Identity stamped on commit/2's commits — set explicitly so a commit never
  # fails on a repo with no user.name/user.email configured, and so harness-made
  # deliveries stay attributable (`git log --author=harness`).
  @committer_name "harness"
  @committer_email "harness@localhost"

  @enforce_keys [:id, :path, :branch, :repo]
  defstruct [:id, :path, :branch, :repo]

  @typedoc "A live worktree handle."
  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          branch: String.t(),
          repo: String.t()
        }

  @typedoc "The verified outcome of a run, driving the keep-or-teardown decision."
  @type outcome :: :success | :failure

  @typedoc "A reason a worktree operation can fail with."
  @type error ::
          {:repo_not_found, String.t()}
          | {:not_a_git_repo, String.t()}
          | {:marker_write_failed, String.t(), File.posix()}
          # Inlined from the internal Harness.Git.error/0 — keeps this public
          # type self-describing without autolinking to a hidden module.
          | {:git_failed, args :: [String.t()], status :: integer(), output :: String.t()}

  @doc """
  Creates an isolated worktree for a run against `repo`.

  Carves a fresh working directory at `<base_dir>/<repo-name>/<id>` and a new
  branch `harness/<id>` off the repo's current `HEAD`. The `id` is unique per
  call, so concurrent `create/2` invocations on the same repo never collide.

  Options:

    * `:base_dir` — override the configured worktree root.
    * `:base_ref` — the commit-ish the new branch forks from. Default `"HEAD"`.
    * `:id` — override the generated run id (intended for tests).

  Returns `{:ok, %Harness.Worktree{}}` or `{:error, reason}` — see `t:error/0`.
  """
  @spec create(String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def create(repo, opts \\ []) when is_binary(repo) do
    repo = Path.expand(repo)
    id = Keyword.get(opts, :id) || generate_id()
    branch = @branch_prefix <> id
    path = Path.join([base_dir(opts), Path.basename(repo), id])
    base_ref = Keyword.get(opts, :base_ref, "HEAD")

    with :ok <- validate_repo(repo),
         {:ok, _output} <- Git.run(["worktree", "add", "-b", branch, path, base_ref], repo) do
      {:ok, %__MODULE__{id: id, path: path, branch: branch, repo: repo}}
    end
  end

  @doc """
  Captures the agent's work as a commit on the worktree's branch.

  Stages every change in the worktree (`git add -A` — the repo's `.gitignore`
  still excludes `_build`, `deps`, and friends) and commits it to the
  `harness/<id>` branch. That commit is the run's deliverable: it is what
  survives `finish/3` teardown, since `remove/1` deletes only the working
  directory.

  The commit carries an explicit committer identity (`#{@committer_name}
  <#{@committer_email}>`), so it never fails on a repo with no `user.name` /
  `user.email` configured.

  Returns:

    * `{:ok, :committed}` — the agent's work was committed.
    * `{:ok, :no_changes}` — the agent left the worktree unchanged; there was
      nothing to commit.
    * `{:error, reason}` — a git invocation failed (see `t:error/0`).
  """
  @spec commit(t(), String.t()) :: {:ok, :committed | :no_changes} | {:error, error()}
  def commit(%__MODULE__{path: path}, message) when is_binary(message) do
    with {:ok, _added} <- Git.run(["add", "-A"], path),
         {:ok, status} <- Git.run(["status", "--porcelain"], path) do
      if String.trim(status) == "" do
        {:ok, :no_changes}
      else
        commit_staged(path, message)
      end
    end
  end

  @doc """
  Returns the changed-line size of the agent diff currently in the worktree.

  The worktree is staged before measurement so untracked files are included,
  matching the diff that `commit/2` will capture.
  """
  @spec diff_size(t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def diff_size(%__MODULE__{path: path}) do
    with {:ok, _added} <- Git.run(["add", "-A"], path),
         {:ok, numstat} <- Git.run(["diff", "--cached", "--numstat", "HEAD", "--"], path) do
      {:ok, parse_numstat_size(numstat)}
    end
  end

  @doc """
  Makes the keep-or-teardown decision when a run completes.

  On `:success` the worktree is torn down (`remove/1`). On `:failure` it is
  retained for inspection when `:retain_on_failure` is set (the default),
  otherwise torn down.

  Options:

    * `:retain_on_failure` — override the configured retain policy.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec finish(t(), outcome(), keyword()) :: :ok | {:error, error()}
  def finish(worktree, outcome, opts \\ [])

  def finish(%__MODULE__{} = worktree, :success, _opts), do: remove(worktree)

  def finish(%__MODULE__{} = worktree, :failure, opts) do
    if retain_on_failure?(opts), do: retain(worktree), else: remove(worktree)
  end

  @doc """
  Tears a worktree down: removes its working directory and prunes git metadata.

  Forced, because a run leaves an uncommitted working tree behind. The
  `harness/<id>` branch is left intact — it carries the run's commits.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec remove(t()) :: :ok | {:error, error()}
  def remove(%__MODULE__{path: path, repo: repo}) do
    with {:ok, _removed} <- Git.run(["worktree", "remove", "--force", path], repo),
         {:ok, _pruned} <- Git.run(["worktree", "prune"], repo) do
      :ok
    end
  end

  @doc """
  Whether the worktree directory at `path` carries the retained-on-failure marker.

  `Harness.Worktree.Sweeper` uses this to tell a deliberately-kept failed run
  from a crash-orphaned worktree.
  """
  @spec retained?(String.t()) :: boolean()
  def retained?(path) do
    path |> Path.join(@retained_marker) |> File.exists?()
  end

  @doc """
  The configured worktree root — `<base_dir>/<repo-name>/<id>` is created under it.

  The `:base_dir` option overrides; otherwise the `:harness, :worktree`
  application config is consulted, falling back to `~/_DATA/worktrees/.harness`.
  """
  @spec base_dir(keyword()) :: String.t()
  def base_dir(opts \\ []) do
    Keyword.get(opts, :base_dir) || config(:base_dir) || Path.expand(@default_base_dir)
  end

  @spec commit_staged(String.t(), String.t()) :: {:ok, :committed} | {:error, error()}
  defp commit_staged(path, message) do
    args = [
      "-c",
      "user.name=#{@committer_name}",
      "-c",
      "user.email=#{@committer_email}",
      "commit",
      "-q",
      "-m",
      message
    ]

    case Git.run(args, path) do
      {:ok, _output} -> {:ok, :committed}
      {:error, _reason} = error -> error
    end
  end

  @spec parse_numstat_size(String.t()) :: non_neg_integer()
  defp parse_numstat_size(numstat) do
    numstat
    |> String.split("\n", trim: true)
    |> Enum.reduce(0, fn line, acc ->
      [added, deleted | _path] = String.split(line, "\t")
      acc + parse_numstat_count(added) + parse_numstat_count(deleted)
    end)
  end

  @spec parse_numstat_count(String.t()) :: non_neg_integer()
  defp parse_numstat_count("-"), do: 0

  defp parse_numstat_count(value) do
    {count, ""} = Integer.parse(value)
    count
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    rand = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "run-#{System.system_time(:millisecond)}-#{rand}"
  end

  @spec validate_repo(String.t()) :: :ok | {:error, error()}
  defp validate_repo(repo) do
    cond do
      not File.dir?(repo) -> {:error, {:repo_not_found, repo}}
      not Git.work_tree?(repo) -> {:error, {:not_a_git_repo, repo}}
      true -> :ok
    end
  end

  @spec retain_on_failure?(keyword()) :: boolean()
  defp retain_on_failure?(opts) do
    case Keyword.fetch(opts, :retain_on_failure) do
      {:ok, value} -> value
      :error -> config(:retain_on_failure) != false
    end
  end

  @spec retain(t()) :: :ok | {:error, error()}
  # `marker` is a fixed filename under the worktree's own harness-created path,
  # not external input.
  # sobelow_skip ["Traversal.FileModule"]
  defp retain(%__MODULE__{path: path, branch: branch}) do
    marker = Path.join(path, @retained_marker)
    body = "retained_at=#{DateTime.to_iso8601(DateTime.utc_now())}\nbranch=#{branch}\n"

    case File.write(marker, body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:marker_write_failed, marker, reason}}
    end
  end

  @spec config(atom()) :: term()
  defp config(key) do
    :harness |> Application.get_env(:worktree, []) |> Keyword.get(key)
  end
end
