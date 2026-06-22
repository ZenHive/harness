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

  Branch deletion and merge. `create/2` carves or resets the `harness/<id>`
  branch and `commit/2` captures the agent's work onto it — those commits are
  the run's deliverable, so teardown removes only the working directory, never
  the branch. Deleting the branch or merging it back is the orchestrator's call.
  A crashed run that never reaches `finish/3` is reaped by the boot-time sweep in
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
  alias Harness.Run.RetryPolicy

  require Logger

  @branch_prefix "harness/"
  @active_marker ".harness-active"
  @retained_marker ".harness-retained"
  @default_base_dir "~/_DATA/worktrees/.harness"

  # The Registry every live Harness.Run gen_statem registers under (keyed by
  # run_id). `cleanup_for_run/2` consults it as the mechanical liveness signal —
  # a run_id present here owns a live process, so its worktree+branch must never
  # be torn down out from under it.
  @run_registry Harness.Run.Registry

  # The run-local agent-artifact directory (`.harness/review.json`,
  # `.harness/audit.json`). Verdict artifacts are read by harness mechanically
  # and must NEVER ride in the deliverable commit.
  @artifact_dir ".harness"

  # The full harness-managed artifact family that must never be staged into an
  # agent commit: the verdict dir plus the run-state markers. Staging excludes it
  # in two moves (`stage_worktree/1`): a *bare* `git add -A` — no pathspec, so a
  # gitignored `.harness/` is silently skipped instead of fataling git's
  # ignored-path guard (`git add` exits 1 whenever ANY explicit pathspec, even an
  # `:(exclude)`, matches a gitignored path) — then a `git reset` that unstages
  # this family (covering both the markers and a *non*-gitignored `.harness/`).
  @artifact_paths [@artifact_dir, @active_marker, @retained_marker]

  # The same family as exclude pathspecs, for the read-only `status`/`diff` calls
  # that filter (rather than stage) the artifacts out of the commit measurement.
  @stage_exclude Enum.map(@artifact_paths, &":(exclude)#{&1}")

  # Ignored-but-load-bearing files the parent checkout carries that the verification
  # stack relies on but that .gitignore keeps out of the worktree-add. `.sobelow-skips`
  # is the line-fingerprint baseline audit-review regenerates; without it every harness
  # worktree re-flags inherited findings. Add new entries here as similar baselines
  # appear (e.g. credo's .credo-skips, a future doctor baseline, etc.).
  @baseline_files [".sobelow-skips"]

  # Gitignored build directories `warm/2` seeds a fresh worktree with by copying
  # them from the parent checkout (CoW-cloned where the filesystem supports it).
  # These are absent in a `git worktree add` tree, so without warming the
  # implementer cold-fetches deps and the reviewer cold-compiles + cold-builds the
  # dialyzer PLT — minutes of work harness can skip by copying already-built bytes.
  # Elixir-shaped by default; override the cross-project fallback per host via
  # `:harness, :worktree, :warm_paths` (e.g. `["target"]` for a Rust target).
  # Per-project `warm_paths` extend that resolved base list. Warming is a pure
  # optimization — never a gate — so an unknown/empty list just means cold builds.
  @default_warm_paths ["deps", "_build", "priv/plts"]

  # Identity stamped on commit/2's commits — set explicitly so a commit never
  # fails on a repo with no user.name/user.email configured, and so harness-made
  # deliveries stay attributable (`git log --author=harness`).
  @committer_name "harness"
  @committer_email "harness@localhost"

  # No-op push target stamped into the run worktree's push path (Task 186). An
  # in-run agent has a full shell in its worktree, so nothing intrinsically stops
  # it running `git push`/`gh pr create` and reaching origin on its own
  # initiative — bypassing the lander, the only place MERGE is supposed to happen
  # (a `:manual` project must see nothing reach origin except by operator action).
  # A local path that is not a git repo makes `git push` fail locally with no
  # network call ("does not appear to be a git repository").
  @push_sentinel "/dev/null"

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
      commits on the branch never shift it. Diff-aware tooling uses it to tell
      agent-added content from inherited debt on the branch.
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
  Where the worktree's HEAD was pointing when `commit/2` could not reconcile it
  onto the run branch — a defensive `:head_moved` backstop only, as the three
  realistic agent moves (HEAD at/ahead/behind the frozen run branch) all
  re-attach losslessly.

  `{:branch, name}` — HEAD was on a different branch. `{:detached, sha}` — HEAD
  was detached (e.g. `git checkout --detach` or `git checkout <sha>`).
  """
  @type head_label :: {:branch, String.t()} | {:detached, String.t()}

  @doc """
  Creates an isolated worktree for a run against `project`.

  Carves a fresh working directory at `<base_dir>/<project.name>/<id>` and a
  branch `harness/<id>` off the resolved `:base_ref` (`HEAD` by default). The
  `id` is unique per call, so concurrent `create/2` invocations on the same
  project never collide. When Oban retries the same logical run after a BEAM
  restart, the stable id may point at a branch left by the crashed attempt;
  that branch is reset and reused.

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
    retry_substrate(opts, fn -> do_create(project, opts) end)
  end

  @spec do_create(Project.t(), keyword()) :: {:ok, t()} | {:error, error()}
  defp do_create(%Project{} = project, opts) do
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
      :ok = neuter_push(path)
      {:ok, %__MODULE__{id: id, path: path, branch: branch, repo: repo, base_sha: base_sha}}
    end
  end

  @doc """
  Seeds a fresh worktree with the parent checkout's already-built artifacts.

  `git worktree add` only materializes tracked files, so the gitignored build
  directories (`deps`, `_build`, the dialyzer PLT under `priv/plts`) are absent
  in a new worktree — leaving the implementer to cold-fetch deps and the reviewer
  to cold-compile and cold-build the PLT, minutes of work per run. This copies
  those directories from the parent checkout (CoW-cloned via `cp -c` where the
  filesystem supports it, plain copy otherwise) so the agent drops into a warmed
  tree and only the changed app modules recompile.

  Pure mechanical byte-copy — the restored-and-decoupled descendant of the warm
  step the agent-gate rebuild deleted along with `Harness.Verification`. It is a
  best-effort optimization, **never a gate**: any copy that fails is logged and
  skipped (the agent simply cold-builds that path), so `warm/2` always returns
  `:ok`. Only paths present in the parent and absent in the worktree are seeded,
  so it never clobbers agent-produced state.

  Which directories to seed starts with the `:harness, :worktree, :warm_paths`
  app config, else `#{inspect(@default_warm_paths)}`. `opts[:warm_paths]` adds
  project-specific directories to that base list.
  """
  @spec warm(t(), keyword()) :: :ok
  def warm(%__MODULE__{path: path, repo: repo}, opts \\ []) do
    seeded =
      Enum.filter(warm_paths(opts), fn rel ->
        seedable?(repo, path, rel) and seed_path(repo, path, rel)
      end)

    if seeded != [] do
      Logger.debug("harness worktree: warmed #{path} with #{Enum.join(seeded, ", ")}")
    end

    :ok
  end

  @spec warm_paths(keyword()) :: [String.t()]
  defp warm_paths(opts) do
    Enum.uniq(resolved_default_warm_paths() ++ Keyword.get(opts, :warm_paths, []))
  end

  @spec resolved_default_warm_paths() :: [String.t()]
  defp resolved_default_warm_paths do
    config(:warm_paths) || @default_warm_paths
  end

  # A path is seedable when the parent checkout has it and the worktree does not —
  # never overwrite something `git worktree add` (or the agent) already produced.
  @spec seedable?(String.t(), String.t(), String.t()) :: boolean()
  defp seedable?(repo, worktree_path, rel) do
    File.exists?(Path.join(repo, rel)) and not File.exists?(Path.join(worktree_path, rel))
  end

  # Copies one build directory parent -> worktree. A failed copy is logged, its
  # partial output removed (so no half-copied tree fools a staleness check into
  # skipping a rebuild), and reported as not-seeded — the agent cold-builds it.
  # sobelow_skip ["Traversal.FileModule"]
  @spec seed_path(String.t(), String.t(), String.t()) :: boolean()
  defp seed_path(repo, worktree_path, rel) do
    src = Path.join(repo, rel)
    dst = Path.join(worktree_path, rel)
    _ = File.mkdir_p(Path.dirname(dst))

    case clone_copy(src, dst) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("harness worktree: warm copy of #{rel} failed: #{inspect(reason)}")
        _ = File.rm_rf(dst)
        false
    end
  end

  # Prefer a copy-on-write clone (`cp -c`, instant + zero extra space on APFS);
  # fall back to a plain recursive copy where the filesystem or `cp` lacks it
  # (Linux/CI). Either way the bytes land — CoW is an efficiency detail, not a
  # correctness requirement.
  @spec clone_copy(String.t(), String.t()) :: :ok | {:error, term()}
  defp clone_copy(src, dst) do
    case System.cmd("cp", ["-cR", src, dst], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {_out, _nonzero} -> fallback_copy(src, dst)
    end
  rescue
    error in [ErlangError, RuntimeError] ->
      Logger.debug("harness worktree: cp clone unavailable (#{inspect(error)}); falling back")
      fallback_copy(src, dst)
  end

  # sobelow_skip ["Traversal.FileModule"]
  @spec fallback_copy(String.t(), String.t()) :: :ok | {:error, term()}
  defp fallback_copy(src, dst) do
    _ = File.rm_rf(dst)

    case File.cp_r(src, dst) do
      {:ok, _copied} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  # Neuters the push path for the run worktree ONLY, so an in-run agent's
  # `git push` fails locally without touching the network (Task 186). Fetch is
  # untouched (`remote.origin.url` still resolves), so the reviewer can still
  # `git fetch origin/<target>` for context.
  #
  # Worktrees SHARE `$GIT_DIR/config` by default, so a plain `git config
  # remote.origin.pushurl` would neuter push in the operator's main checkout AND
  # the lander (which pushes from the parent repo) — exactly what must keep
  # working. `extensions.worktreeConfig` + `git config --worktree` scopes the
  # override to `$GIT_DIR/worktrees/<id>/config.worktree`, read only by this
  # worktree. `checkout_existing/2` (the lander's detached worktree) is left
  # alone on purpose.
  #
  # Best-effort: a config failure logs and proceeds — this guard is
  # defense-in-depth, not a precondition for the worktree being usable.
  @spec neuter_push(String.t()) :: :ok
  defp neuter_push(path) do
    with {:ok, _} <- Git.run(["config", "extensions.worktreeConfig", "true"], path),
         {:ok, _} <- Git.run(["config", "--worktree", "remote.origin.pushurl", @push_sentinel], path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("harness worktree: push-neuter failed for #{path}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Checks an *existing* ref out into a fresh **detached** worktree.

  Unlike `create/2`, which carves a new `harness/<id>` branch off a base ref,
  this checks out an already-existing ref (a settled run's retained
  `harness/<run-id>` branch, or `origin/<target>` for a post-merge audit) so the
  autonomous lander / audit worker can operate on its tree. The checkout is
  always `--detach`: HEAD points at the ref's commit, not the ref itself, so the
  checkout never conflicts with the same branch being checked out in another
  worktree (the run's retained worktree, the operator's checkout).

  Carves the working directory at `<base_dir>/<repo-basename>/landing/<id>` by
  default; override with the `:path` option.

  Options:

    * `:path` — explicit worktree directory (intended for tests).
    * `:base_dir` — override the configured worktree root.
    * `:id` — override the generated id used in the default path.

  Returns `{:ok, %Harness.Worktree{}}` whose `branch` is the requested ref name
  (for reference; HEAD is detached) and `base_sha` its tip at checkout, or
  `{:error, reason}` — see `t:error/0`. Tear down with `remove/1`.
  """
  @spec checkout_existing(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def checkout_existing(repo, ref, opts \\ []) when is_binary(repo) and is_binary(ref) do
    id = Keyword.get(opts, :id) || generate_id()
    path = Keyword.get(opts, :path) || Path.join([base_dir(opts), repo_slug(repo), "landing", id])

    with :ok <- validate_repo(repo),
         {:ok, _output} <- locked_worktree_add(repo, ["worktree", "add", "--detach", path, ref]),
         {:ok, base_sha} <- resolve_base_sha(path) do
      {:ok, %__MODULE__{id: id, path: path, branch: ref, repo: repo, base_sha: base_sha}}
    end
  end

  @spec repo_slug(String.t()) :: String.t()
  defp repo_slug(repo), do: repo |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")

  @spec add_worktree(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  defp add_worktree(repo, branch, path, base_ref) do
    locked_worktree_add(repo, ["worktree", "add", "-B", branch, path, base_ref])
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
  # `git worktree add -B`; capture it as the worktree's stable base SHA before
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
  `deps`, and friends; the `.harness/` artifact directory holding the reviewer's
  `review.json` verdict is always excluded) and commits it to the
  `harness/<id>` branch. That commit
  is the run's deliverable: it is what survives `finish/3` teardown, since
  `remove/1` deletes only the working directory.

  The commit carries an explicit committer identity (`#{@committer_name}
  <#{@committer_email}>`), so it never fails on a repo with no `user.name` /
  `user.email` configured.

  Before staging, re-attaches HEAD to its own `harness/<id>` branch via
  `reconcile_head_to_branch/2`. An agent that ran `git switch`/`git checkout`
  (or detached HEAD) inside the worktree would otherwise land the commit
  off-branch, where teardown then loses it. Because the run branch is frozen
  once HEAD leaves it, re-attaching is always a lossless git op (fast-forwarding
  the branch onto any detached-ahead commits first) — never a judgment call.

  Returns:

    * `{:ok, :committed}` — the agent's work was committed.
    * `{:ok, :no_changes}` — the agent left the worktree unchanged (including
      when re-attachment fast-forwarded the branch onto a commit the agent
      already made while detached); there was nothing further to commit.
    * `{:error, reason}` — HEAD could not be reconciled onto the run branch
      (the unreachable divergence backstop), or a git invocation failed (see
      `t:error/0`).
  """
  @spec commit(t(), String.t(), keyword()) :: {:ok, :committed | :no_changes} | {:error, error()}
  def commit(worktree, message, opts \\ [])

  def commit(%__MODULE__{} = worktree, message, opts) when is_binary(message) do
    retry_substrate(opts, fn -> do_commit(worktree, message) end)
  end

  @spec do_commit(t(), String.t()) :: {:ok, :committed | :no_changes} | {:error, error()}
  defp do_commit(%__MODULE__{path: path, branch: branch}, message) do
    with :ok <- prepare_for_staging(path),
         :ok <- reconcile_head_to_branch(path, branch),
         {:ok, _staged} <- stage_worktree(path),
         {:ok, status} <- Git.run(["status", "--porcelain", "--"] ++ @stage_exclude, path) do
      if String.trim(status) == "" do
        {:ok, :no_changes}
      else
        commit_staged(path, message)
      end
    end
  end

  # Stage every agent change while keeping the harness artifact family
  # (`@artifact_paths`) out of the index. Two moves are required, not one:
  # `git add` exits 1 whenever an *explicit* pathspec (even an `:(exclude)` one)
  # matches a gitignored path, so a target repo that gitignores `.harness/` (with
  # the reviewer's `.harness/review.json` present) fatals the whole stage. A
  # *bare* `git add -A` carries no pathspec, so git silently skips the gitignored
  # dir instead of erroring; the follow-up `git reset` then unstages the artifact
  # family in the other repo state — where `.harness/` is *not* gitignored and
  # `git add -A` would otherwise stage it (and always stages the un-ignored
  # `.harness-retained`/`.harness-active` markers). `reset` never errors on an
  # absent/unstaged path, so the call is a no-op when no artifact was staged.
  @spec stage_worktree(String.t()) :: {:ok, String.t()} | {:error, error()}
  defp stage_worktree(path) do
    with {:ok, _added} <- Git.run(["add", "-A"], path) do
      Git.run(["reset", "-q", "--" | @artifact_paths], path)
    end
  end

  @spec retry_substrate(keyword(), (-> term())) :: term()
  defp retry_substrate(opts, fun) when is_function(fun, 0) do
    policy = opts |> Keyword.get(:substrate_retry, []) |> RetryPolicy.new()
    RetryPolicy.retry(fun, policy)
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
         {:ok, _staged} <- stage_worktree(path),
         {:ok, numstat} <- Git.run(["diff", "--cached", "--numstat", "HEAD", "--"] ++ @stage_exclude, path) do
      {:ok, parse_numstat_size(numstat)}
    end
  end

  @doc """
  Returns the changed-line size of the worktree's committed work since `ref`.

  Measures `ref..HEAD` excluding `.harness/` artifacts — the mechanical "how
  much did this stage change" signal, e.g. the reviewer's own fixes on top of
  the implementer's delivery commit.
  """
  @spec diff_size_since(t(), String.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def diff_size_since(%__MODULE__{path: path}, ref) when is_binary(ref) do
    with :ok <- assert_worktree_dir(path),
         {:ok, numstat} <- Git.run(["diff", "--numstat", "#{ref}..HEAD", "--"] ++ @stage_exclude, path) do
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
  SAME run id must be able to run `git worktree add -B harness/<run_id>` again,
  which collides with both the worktree registration and the branch a failed
  prior attempt left behind (the 2026-06-02 branch-collision cascade). It is
  never called on a settled run — settled failures retain their worktrees (and
  always their branches) for salvage by design.

  ## Liveness guard

  A second Oban attempt can re-run while the FIRST attempt's gen_statem is still
  alive (an `:already_started` registry collision). Tearing down then would
  destroy a live run's worktree+branch mid-flight (the 2026-06-03 job-118
  live-destruction case → `{:worktree_missing}` at `:reviewing`). So this refuses
  outright when `run_id` is still registered in `Harness.Run.Registry`: a live
  run owns its checkout, and no retry/rescue path may reap it.

  Idempotent and best-effort: every step tolerates "already gone", and a git
  failure on one step never prevents the others. Returns `{:error, :live_run}`
  only when the liveness guard refuses to touch a registered run.
  """
  @spec cleanup_for_run(String.t(), String.t()) :: :ok | {:error, :live_run}
  def cleanup_for_run(repo, run_id) when is_binary(repo) and is_binary(run_id) do
    if live_run?(run_id) do
      Logger.warning(
        "Harness.Worktree.cleanup_for_run refused for live run #{run_id}: " <>
          "gen_statem still registered; leaving its worktree and branch intact."
      )

      {:error, :live_run}
    else
      do_cleanup_for_run(repo, run_id)
    end
  end

  @spec do_cleanup_for_run(String.t(), String.t()) :: :ok
  defp do_cleanup_for_run(repo, run_id) do
    branch = @branch_prefix <> run_id

    Enum.each(worktree_paths_for_branch(repo, branch), fn path ->
      _ = Git.run(["worktree", "remove", "--force", path], repo)
    end)

    _ = Git.run(["worktree", "prune"], repo)
    _ = Git.run(["branch", "-D", branch], repo)
    :ok
  end

  # Mechanical liveness signal: a run_id registered in Harness.Run.Registry owns
  # a live gen_statem. Guarded against the registry being unstarted (no live runs
  # ⇒ false) so cleanup never crashes on a bare unit boot.
  @spec live_run?(String.t()) :: boolean()
  defp live_run?(run_id) do
    case Process.whereis(@run_registry) do
      nil -> false
      _pid -> Registry.lookup(@run_registry, run_id) != []
    end
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

  # Re-attaches HEAD to the run's `harness/<id>` branch before staging, so an
  # agent that ran `git switch`/`git checkout`/`--detach` inside the worktree
  # can't strand its work off-branch (where teardown would lose it). This is
  # pure git mechanics, never a judgment call: the run branch only ever advances
  # while HEAD is on it, so once the agent moves HEAD the branch is FROZEN — and
  # a frozen branch vs a moved HEAD is always one of three lossless cases:
  #   * HEAD at the branch tip → re-attach (`git checkout <branch>`).
  #   * HEAD behind the tip (agent checked out an older commit) → re-attach;
  #     the branch already holds everything, working-tree edits carry over.
  #   * HEAD ahead of the tip (agent committed while detached) → fast-forward
  #     the branch onto the agent's commits, then re-attach.
  # Genuine divergence (each side holding commits the other lacks) is UNREACHABLE
  # here — there is no second writer to advance the branch — so it needs no agent
  # merge-reconciler; it stays a defensive `:head_moved` backstop only.
  @spec reconcile_head_to_branch(String.t(), String.t()) :: :ok | {:error, error()}
  defp reconcile_head_to_branch(path, branch) do
    with {:ok, current} <- Git.run(["branch", "--show-current"], path) do
      if String.trim(current) == branch, do: :ok, else: reattach_head(path, branch, String.trim(current))
    end
  end

  @spec reattach_head(String.t(), String.t(), String.t()) :: :ok | {:error, error()}
  defp reattach_head(path, branch, current) do
    with {:ok, head} <- rev_parse(path, "HEAD"),
         {:ok, tip} <- rev_parse(path, branch),
         {:ok, base} <- rev_parse(path, ["merge-base", head, tip]) do
      cond do
        head == tip or base == head -> checkout(path, branch)
        base == tip -> fast_forward(path, branch, head)
        true -> {:error, {:head_moved, branch, head_label(current, head)}}
      end
    end
  end

  @spec rev_parse(String.t(), String.t() | [String.t()]) :: {:ok, String.t()} | {:error, error()}
  defp rev_parse(path, ref) when is_binary(ref), do: rev_parse(path, ["rev-parse", ref])

  defp rev_parse(path, args) when is_list(args) do
    with {:ok, output} <- Git.run(args, path), do: {:ok, String.trim(output)}
  end

  @spec checkout(String.t(), String.t()) :: :ok | {:error, error()}
  defp checkout(path, branch) do
    with {:ok, _output} <- Git.run(["checkout", branch], path), do: :ok
  end

  @spec fast_forward(String.t(), String.t(), String.t()) :: :ok | {:error, error()}
  defp fast_forward(path, branch, head) do
    with {:ok, _moved} <- Git.run(["branch", "-f", branch, head], path), do: checkout(path, branch)
  end

  @spec head_label(String.t(), String.t()) :: head_label()
  defp head_label("", head), do: {:detached, head}
  defp head_label(current, _head), do: {:branch, current}

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
    match?({_output, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  @spec config(atom()) :: term()
  defp config(key) do
    :harness |> Application.get_env(:worktree, []) |> Keyword.get(key)
  end
end
