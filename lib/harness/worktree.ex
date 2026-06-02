defmodule Harness.Worktree do
  @moduledoc """
  Per-run git worktree lifecycle.

  Every harness run executes inside its own git worktree: an isolated working
  directory and branch carved out of a target repository. Isolation means
  concurrent runs never collide on the working tree, and the verification stack
  always grades a clean checkout.

  ## Lifecycle

      {:ok, wt} = Harness.Worktree.create(project)
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

  alias Harness.AgentRules
  alias Harness.Git
  alias Harness.Project

  @branch_prefix "harness/"
  @active_marker ".harness-active"
  @retained_marker ".harness-retained"
  @default_base_dir "~/_DATA/worktrees/.harness"

  # Ignored-but-load-bearing files the parent checkout carries that the verification
  # stack relies on but that .gitignore keeps out of the worktree-add. `.sobelow-skips`
  # is the line-fingerprint baseline audit-review regenerates; without it every harness
  # worktree re-flags inherited findings. Add new entries here as similar baselines
  # appear (e.g. credo's .credo-skips, a future doctor baseline, etc.).
  @baseline_files [".sobelow-skips"]

  # Identity stamped on commit/2's commits — set explicitly so a commit never
  # fails on a repo with no user.name/user.email configured, and so harness-made
  # deliveries stay attributable (`git log --author=harness`).
  @committer_name "harness"
  @committer_email "harness@localhost"

  @enforce_keys [:id, :path, :branch, :repo, :base_sha]
  defstruct [:id, :path, :branch, :repo, :base_sha]

  @typedoc """
  A live worktree handle.

    * `id` — the worktree's unique id.
    * `path` — the worktree's working directory.
    * `branch` — the `harness/<id>` branch carved at creation.
    * `repo` — the parent repository the worktree was carved out of.
    * `base_sha` — the commit SHA the `harness/<id>` branch was forked from
      (the resolved `:base_ref`). Stable for the worktree's lifetime; later
      commits on the branch never shift it. Diff-aware tooling (e.g. the
      verification stack's baseline-TODO filter) uses it to tell agent-added
      content from inherited debt.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          branch: String.t(),
          repo: String.t(),
          base_sha: String.t()
        }

  @typedoc "The verified outcome of a run, driving the keep-or-teardown decision."
  @type outcome :: :success | :failure

  @typedoc "A reason a worktree operation can fail with."
  @type error ::
          {:repo_not_found, String.t()}
          | {:not_a_git_repo, String.t()}
          | {:worktree_missing, String.t()}
          | {:marker_write_failed, String.t(), File.posix()}
          | {:rule_cleanup_failed, String.t(), File.posix()}
          | {:head_moved, expected :: String.t(), actual :: head_label()}
          | {:worktree_lock_aborted, String.t()}
          | {:source_unavailable, term()}
          # Inlined from the internal Harness.Git.error/0 — keeps this public
          # type self-describing without autolinking to a hidden module.
          | {:git_failed, args :: [String.t()], status :: integer(), output :: String.t()}

  @typedoc """
  Where the worktree's HEAD was actually pointing when `commit/2` rejected it.

  `{:branch, name}` — the agent ran `git switch`/`git checkout` to a different
  branch. `{:detached, sha}` — the agent detached HEAD (e.g. `git checkout
  --detach` or `git checkout <sha>`).
  """
  @type head_label :: {:branch, String.t()} | {:detached, String.t()}

  @doc """
  Creates an isolated worktree for a run against `project`.

  Carves a fresh working directory at `<base_dir>/<project.name>/<id>` and a new
  branch `harness/<id>` off the repo's current `HEAD`. The `id` is unique per
  call, so concurrent `create/2` invocations on the same project never collide.

  For `{:github, _}` sources, this also clones the upstream into the project's
  cache (`<cache_root>/<project.name>`) on first call, and `git fetch`es +
  fast-forwards the default branch on every subsequent call — so a worktree is
  never carved off a stale `main`. See `Harness.Project.Source.Github`.

  Options:

    * `:base_dir` — override the configured worktree root.
    * `:base_ref` — the commit-ish the new branch forks from. Default `"HEAD"`.
    * `:id` — override the generated run id (intended for tests).
    * `:cache_root` — override the GitHub-source cache root (intended for tests).

  Returns `{:ok, %Harness.Worktree{}}` or `{:error, reason}` — see `t:error/0`.
  """
  @spec create(Project.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def create(%Project{} = project, opts \\ []) do
    id = Keyword.get(opts, :id) || generate_id()
    branch = @branch_prefix <> id
    path = Path.join([base_dir(opts), project.name, id])
    base_ref = Keyword.get(opts, :base_ref, "HEAD")
    ensure_opts = Keyword.take(opts, [:cache_root])

    with {:ok, repo} <- ensure_repo(project, ensure_opts),
         :ok <- validate_repo(repo),
         {:ok, _output} <- add_worktree(repo, branch, path, base_ref),
         {:ok, base_sha} <- resolve_base_sha(path) do
      :ok = propagate_baseline_files(repo, path)
      {:ok, %__MODULE__{id: id, path: path, branch: branch, repo: repo, base_sha: base_sha}}
    end
  end

  @doc """
  Checks an *existing* branch out into a fresh worktree.

  Unlike `create/2`, which carves a new `harness/<id>` branch off a base ref,
  this checks out an already-existing branch (e.g. a settled run's retained
  `harness/<run-id>`) so the autonomous lander can rebase + re-verify the
  integrated state on it. A branch can only be checked out in one worktree at a
  time — the run's own worktree is already torn down on success, so its branch
  is free.

  Carves the working directory at `<base_dir>/<repo-basename>/landing/<id>` by
  default; override with the `:path` option.

  Options:

    * `:path` — explicit worktree directory (intended for tests).
    * `:base_dir` — override the configured worktree root.
    * `:id` — override the generated id used in the default path.

  Returns `{:ok, %Harness.Worktree{}}` whose `branch` is the checked-out branch
  and `base_sha` its tip at checkout, or `{:error, reason}` — see `t:error/0`.
  Tear down with `remove/1`.
  """
  @spec checkout_existing(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def checkout_existing(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) do
    id = Keyword.get(opts, :id) || generate_id()
    path = Keyword.get(opts, :path) || Path.join([base_dir(opts), repo_slug(repo), "landing", id])

    with :ok <- validate_repo(repo),
         {:ok, _output} <- locked_worktree_add(repo, ["worktree", "add", path, branch]),
         {:ok, base_sha} <- resolve_base_sha(path) do
      {:ok, %__MODULE__{id: id, path: path, branch: branch, repo: repo, base_sha: base_sha}}
    end
  end

  @spec repo_slug(String.t()) :: String.t()
  defp repo_slug(repo), do: repo |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")

  @spec add_worktree(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  defp add_worktree(repo, branch, path, base_ref) do
    locked_worktree_add(repo, ["worktree", "add", "-b", branch, path, base_ref])
  end

  # Serializes `git worktree add` per parent repo. Concurrent adds against one
  # repo contend on git's repo-level locks (the worktrees registry under
  # `$GIT_DIR/worktrees/`, plus config/HEAD writes); under load one loser comes
  # back `{:git_failed, …}`, which surfaces as a spurious add collision.
  # `:global.trans/2` (infinite retries) lets each add take the lock in turn —
  # the id is `{ResourceId, LockRequesterId}`, so `self()` keys it per caller for
  # mutual exclusion. The add is fast (~tens of ms) so the queue drains quickly.
  @spec locked_worktree_add(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, error()}
  defp locked_worktree_add(repo, args) do
    case :global.trans(
           {{__MODULE__, :worktree_add, repo}, self()},
           fn -> Git.run(args, repo) end
         ) do
      :aborted -> {:error, {:worktree_lock_aborted, repo}}
      result -> result
    end
  end

  # Copies ignored-but-load-bearing baseline files (see @baseline_files) from the
  # parent checkout into the new worktree. These files are gitignored so
  # `git worktree add` does not propagate them — without this, the verification
  # stack re-flags every finding the parent's baseline suppresses.
  # sobelow_skip ["Traversal.FileModule"]
  @spec propagate_baseline_files(String.t(), String.t()) :: :ok
  defp propagate_baseline_files(repo, worktree_path) do
    Enum.each(@baseline_files, fn name ->
      src = Path.join(repo, name)

      if File.regular?(src) do
        dst = Path.join(worktree_path, name)
        _ = File.cp(src, dst)
      end
    end)
  end

  @spec ensure_repo(Project.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  defp ensure_repo(%Project{} = project, opts) do
    case Project.ensure_local_repo(project, opts) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:source_unavailable, reason}}
    end
  end

  # The new branch's HEAD points at the resolved base_ref's commit right after
  # `git worktree add -b`; capture it as the worktree's stable base SHA before
  # any further commits land on the branch.
  @spec resolve_base_sha(String.t()) :: {:ok, String.t()} | {:error, error()}
  defp resolve_base_sha(path) do
    with {:ok, output} <- Git.run(["rev-parse", "HEAD"], path) do
      {:ok, String.trim(output)}
    end
  end

  @doc """
  Captures the agent's work as a commit on the worktree's branch.

  Discards harness-injected rule files, then stages every remaining change in
  the worktree (`git add -A` — the repo's `.gitignore` still excludes `_build`,
  `deps`, and friends) and commits it to the `harness/<id>` branch. That commit
  is the run's deliverable: it is what survives `finish/3` teardown, since
  `remove/1` deletes only the working directory.

  The commit carries an explicit committer identity (`#{@committer_name}
  <#{@committer_email}>`), so it never fails on a repo with no `user.name` /
  `user.email` configured.

  Before staging, asserts the worktree's HEAD still points at its own
  `harness/<id>` branch. An agent that ran `git switch`/`git checkout` (or
  detached HEAD) inside the worktree would otherwise land the commit
  off-branch, where teardown then loses it. If HEAD has moved, no commit is
  made and `{:error, {:head_moved, expected, actual}}` is returned — the
  agent's work stays in the working tree for the retained-on-failure path to
  preserve.

  Returns:

    * `{:ok, :committed}` — the agent's work was committed.
    * `{:ok, :no_changes}` — the agent left the worktree unchanged; there was
      nothing to commit.
    * `{:error, reason}` — HEAD moved off the run branch, or a git invocation
      failed (see `t:error/0`).
  """
  @spec commit(t(), String.t()) :: {:ok, :committed | :no_changes} | {:error, error()}
  def commit(%__MODULE__{path: path, branch: branch}, message) when is_binary(message) do
    with :ok <- prepare_for_staging(path),
         :ok <- assert_head_on_branch(path, branch),
         {:ok, _added} <- Git.run(["add", "-A"], path),
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

  Harness-injected rule files are discarded, then the worktree is staged before
  measurement so untracked files are included, matching the diff that `commit/2`
  will capture.
  """
  @spec diff_size(t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def diff_size(%__MODULE__{path: path}) do
    with :ok <- prepare_for_staging(path),
         {:ok, _added} <- Git.run(["add", "-A"], path),
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

  def finish(%__MODULE__{} = worktree, :success, _opts) do
    with :ok <- deactivate(worktree) do
      remove(worktree)
    end
  end

  def finish(%__MODULE__{} = worktree, :failure, opts) do
    with :ok <- deactivate(worktree) do
      if retain_on_failure?(opts), do: retain(worktree), else: remove(worktree)
    end
  end

  @doc """
  Marks a worktree as owned by a live harness process.

  The boot sweeper preserves active worktrees so a second harness process cannot
  reap a run directory while its adapter port is still running. The marker is
  removed before staging, so it never becomes part of a delivery commit.
  """
  @spec activate(t()) :: :ok | {:error, error()}
  # `marker` is a fixed filename under a harness-created worktree path, not
  # external input.
  # sobelow_skip ["Traversal.FileModule"]
  def activate(%__MODULE__{path: path, id: id, branch: branch}) do
    with :ok <- assert_worktree_dir(path) do
      marker = Path.join(path, @active_marker)

      body =
        "active_at=#{DateTime.to_iso8601(DateTime.utc_now())}\n" <>
          "owner_os_pid=#{System.pid()}\n" <>
          "id=#{id}\n" <>
          "branch=#{branch}\n"

      case File.write(marker, body) do
        :ok -> :ok
        {:error, reason} -> {:error, {:marker_write_failed, marker, reason}}
      end
    end
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
  Best-effort cleanup of everything a prior attempt of `run_id` left behind:
  the worktree directory registered for its `harness/<run_id>` branch (if any)
  and the branch itself (if it exists).

  This is the mechanical-retry hook (`Harness.Run.Worker`): re-attempting the
  SAME run id must be able to run `git worktree add -b harness/<run_id>` again,
  which collides with both the worktree registration and the branch a failed
  prior attempt left behind (the 2026-06-02 branch-collision cascade). It is
  never called on a settled run — settled failures retain their worktrees (and
  always their branches) for salvage by design.

  Idempotent and best-effort: every step tolerates "already gone", and a git
  failure on one step never prevents the others. Always returns `:ok`.
  """
  @spec cleanup_for_run(String.t(), String.t()) :: :ok
  def cleanup_for_run(repo, run_id) when is_binary(repo) and is_binary(run_id) do
    branch = @branch_prefix <> run_id

    Enum.each(worktree_paths_for_branch(repo, branch), fn path ->
      _ = Git.run(["worktree", "remove", "--force", path], repo)
    end)

    _ = Git.run(["worktree", "prune"], repo)
    _ = Git.run(["branch", "-D", branch], repo)
    :ok
  end

  # Parses `git worktree list --porcelain` into the working-directory paths
  # whose checked-out branch is `branch`. Stanzas are blank-line-separated
  # blocks starting with `worktree <path>`, carrying a `branch refs/heads/<name>`
  # line when the worktree is on a branch.
  @spec worktree_paths_for_branch(String.t(), String.t()) :: [String.t()]
  defp worktree_paths_for_branch(repo, branch) do
    case Git.run(["worktree", "list", "--porcelain"], repo) do
      {:ok, output} ->
        branch_line = ~r/^branch refs\/heads\/#{Regex.escape(branch)}$/m

        output
        |> String.split("\n\n", trim: true)
        |> Enum.filter(&Regex.match?(branch_line, &1))
        |> Enum.flat_map(&stanza_worktree_path/1)

      {:error, _reason} ->
        []
    end
  end

  @spec stanza_worktree_path(String.t()) :: [String.t()]
  defp stanza_worktree_path(stanza) do
    case Regex.run(~r/^worktree (.+)$/m, stanza) do
      [_, path] -> [path]
      _other -> []
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
  Whether the worktree directory at `path` carries an active marker for a live
  harness process.
  """
  @spec active?(String.t()) :: boolean()
  def active?(path) do
    path
    |> Path.join(@active_marker)
    |> read_active_owner_pid()
    |> live_owner_pid?()
  end

  @doc """
  The configured worktree root — `<base_dir>/<project-name>/<id>` is created under it.

  The `:base_dir` option overrides; otherwise the `:harness, :worktree`
  application config is consulted, falling back to `~/_DATA/worktrees/.harness`.
  """
  @spec base_dir(keyword()) :: String.t()
  def base_dir(opts \\ []) do
    Keyword.get(opts, :base_dir) || config(:base_dir) || Path.expand(@default_base_dir)
  end

  # Verifies the worktree's HEAD still points at its own `harness/<id>` branch.
  # An agent that ran `git switch`/`git checkout` (or detached HEAD) would
  # otherwise have its work commit land off-branch, where worktree teardown
  # would then lose it. `git branch --show-current` exits 0 either way, emitting
  # the branch name when on a branch or an empty string when detached.
  @spec assert_head_on_branch(String.t(), String.t()) :: :ok | {:error, error()}
  defp assert_head_on_branch(path, expected_branch) do
    with {:ok, output} <- Git.run(["branch", "--show-current"], path) do
      actual = String.trim(output)

      cond do
        actual == expected_branch -> :ok
        actual == "" -> {:error, {:head_moved, expected_branch, {:detached, current_head_sha(path)}}}
        true -> {:error, {:head_moved, expected_branch, {:branch, actual}}}
      end
    end
  end

  @spec current_head_sha(String.t()) :: String.t()
  defp current_head_sha(path) do
    case Git.run(["rev-parse", "HEAD"], path) do
      {:ok, output} -> String.trim(output)
      {:error, _reason} -> "unknown"
    end
  end

  @spec prepare_for_staging(String.t()) :: :ok | {:error, error()}
  defp prepare_for_staging(path) do
    with :ok <- assert_worktree_dir(path),
         :ok <- remove_marker(Path.join(path, @active_marker)) do
      cleanup_injected_rules(path)
    end
  end

  @spec assert_worktree_dir(String.t()) :: :ok | {:error, {:worktree_missing, String.t()}}
  defp assert_worktree_dir(path) do
    if File.dir?(path), do: :ok, else: {:error, {:worktree_missing, path}}
  end

  @spec cleanup_injected_rules(String.t()) :: :ok | {:error, error()}
  defp cleanup_injected_rules(path) do
    AgentRules.cleanup_injected_rules(path)
  rescue
    error in ArgumentError ->
      if File.dir?(path), do: reraise(error, __STACKTRACE__), else: {:error, {:worktree_missing, path}}
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

  # `git diff --numstat` emits `-` for binary files; any other non-integer token
  # (an unexpected git output variant) counts as 0 rather than crashing the
  # surrounding `diff_size/1`.
  @spec parse_numstat_count(String.t()) :: non_neg_integer()
  defp parse_numstat_count("-"), do: 0

  defp parse_numstat_count(value) do
    case Integer.parse(value) do
      {count, ""} -> count
      _ -> 0
    end
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

  @spec deactivate(t()) :: :ok | {:error, error()}
  defp deactivate(%__MODULE__{path: path}) do
    remove_marker(Path.join(path, @active_marker))
  end

  @spec remove_marker(String.t()) :: :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  # `path` is a fixed marker filename under a harness-created worktree path, not
  # external input.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_marker(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:rule_cleanup_failed, path, reason}}
    end
  end

  @spec read_active_owner_pid(String.t()) :: String.t() | nil
  # `marker` is a fixed filename under a harness-created worktree path, not
  # external input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_active_owner_pid(marker) do
    with {:ok, body} <- File.read(marker),
         [_line, pid] <- Regex.run(~r/^owner_os_pid=(\d+)$/m, body) do
      pid
    else
      _other -> nil
    end
  end

  @spec live_owner_pid?(String.t() | nil) :: boolean()
  defp live_owner_pid?(nil), do: false

  defp live_owner_pid?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  @spec config(atom()) :: term()
  defp config(key) do
    :harness |> Application.get_env(:worktree, []) |> Keyword.get(key)
  end
end
