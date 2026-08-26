defmodule Harness.Roadmap.Durable do
  @moduledoc """
  Makes an rmap status transition a durable git operation, not an uncommitted
  local-file write.

  The multi-writer hazard `rmap.md` documents for human sessions — a stale
  on-disk `roadmap/tasks.toml` silently clobbering a concurrent writer — applies
  to harness itself: its dispatch lifecycle mutates the *canonical* roadmap
  (`in_progress` at dispatch start; `done`/`pending`/`blocked` at settle) but
  historically treated those as ephemeral local writes that never fetched,
  committed, or pushed. So every harness run raced every other session and cloud
  agent against the same shared file. This module closes that gap. For each
  transition it:

    1. fetches the roadmap repository's configured branch so it never writes
       from a stale copy,
    2. applies the rmap mutation against a fresh **detached** worktree at the
       freshly-fetched `origin/<target>` tip (rmap auto-renders `tasks.toml`,
       `data.json`, and `ROADMAP.md` on success),
    3. commits the roadmap change and fast-forward-pushes it to the target,
    4. on a non-ff push (a concurrent writer landed first) re-fetches, replays
       the mutation on the new tip, and retries — **never** `--force`,
    5. fast-forwards the operator's *local* target to the pushed commit
       (`Harness.Git.TargetSync`, ff-only, never touching a dirty, diverged, or
       self-host checkout) so the on-disk `tasks.toml` doesn't drift behind origin.

  The mutation itself runs in a throwaway detached worktree (the operator's
  checkout is never the scratch tree); step 5 then syncs that checkout forward so
  concurrent sessions, cloud agents, and other harness runs can no longer
  silently clobber — or fall behind — each other's roadmap edits. Skipping the
  local sync is exactly how `tasks.toml` goes out of sync and a later merge
  breaks, so it is part of the durable write, not an afterthought.

  Mechanical substrate only — no judgment about *whether* to mutate, just the
  git + rmap-shell sequence that makes the transition survive concurrent writers.
  """

  alias Harness.Git
  alias Harness.Git.TargetSync
  alias Harness.Worktree

  require Logger

  # Mirrors Harness.Worktree's committer identity so a roadmap commit never fails
  # on a repo with no user.name/user.email configured and stays attributable.
  @committer_name "harness"
  @committer_email "harness@localhost"

  # Non-ff retry cap: a transition that loses the push race this many times in a
  # row surfaces an error rather than looping forever. Each loss re-fetches the
  # winner's tip and replays the mutation, so convergence is fast in practice.
  @default_max_attempts 5

  @typedoc "Runs the rmap status mutation against the roadmap rooted at the given path."
  @type apply_fun :: (String.t() -> {:ok, String.t()} | {:error, term()})

  @typedoc "A reason a durable roadmap write can fail with."
  @type error ::
          {:roadmap_fetch_failed, term()}
          | {:roadmap_checkout_failed, term()}
          | {:roadmap_stage_failed, term()}
          | {:roadmap_commit_failed, term()}
          | {:roadmap_push_failed, String.t()}
          | {:roadmap_push_unverified, String.t(), term()}
          | {:roadmap_push_exhausted, String.t(), pos_integer()}
          | term()

  @doc """
  Applies an rmap mutation durably against `repo`'s explicitly resolved roadmap
  branch.

  `apply_fun` receives the detached worktree's root and must run the actual rmap
  `status` mutation there, so it writes the freshly-fetched copy rather than a
  stale one. Returns the rmap output on `{:ok, output}`; on a non-ff push it
  replays `apply_fun` on the re-fetched tip up to `:max_attempts` times before
  returning `{:error, {:roadmap_push_exhausted, target, max}}`.

  An rmap mutation that produces no file change (an already-in-that-state no-op)
  commits and pushes nothing and returns its `{:ok, output}` directly.

  Options:

    * `:message` — the commit subject (required).
    * `:apply` — the `t:apply_fun/0` (required).
    * `:max_attempts` — non-ff retry cap (default `#{@default_max_attempts}`).

  Returns `{:ok, output}` or `{:error, reason}` — see `t:error/0`.
  """
  @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def commit(repo, target, opts) when is_binary(repo) and is_binary(target) do
    message = Keyword.fetch!(opts, :message)
    apply_fun = Keyword.fetch!(opts, :apply)
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    attempt(repo, target, message, apply_fun, 1, max_attempts)
  end

  @spec attempt(String.t(), String.t(), String.t(), apply_fun(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, error()}
  defp attempt(_repo, target, _message, _apply_fun, n, max) when n > max do
    {:error, {:roadmap_push_exhausted, target, max}}
  end

  defp attempt(repo, target, message, apply_fun, n, max) do
    with :ok <- fetch(repo, target),
         {:ok, worktree} <- checkout(repo, target) do
      result = mutate_and_push(repo, worktree, target, message, apply_fun)
      cleanup(worktree)

      case result do
        {:retry, _output} -> attempt(repo, target, message, apply_fun, n + 1, max)
        terminal -> terminal
      end
    end
  end

  @spec mutate_and_push(String.t(), Worktree.t(), String.t(), String.t(), apply_fun()) ::
          {:ok, String.t()} | {:retry, String.t()} | {:error, error()}
  defp mutate_and_push(repo, %Worktree{path: path}, target, message, apply_fun) do
    case apply_fun.(path) do
      {:ok, output} ->
        case stage_and_commit(path, message) do
          {:ok, :committed} -> finalize(repo, path, target, output)
          {:ok, :no_changes} -> {:ok, output}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec finalize(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:retry, String.t()} | {:error, error()}
  defp finalize(repo, path, target, output) do
    case push(path, target) do
      :ok ->
        sync_local(repo, target)
        {:ok, output}

      :retry ->
        {:retry, output}

      {:error, _reason} = error ->
        error
    end
  end

  # Keep the operator's local target current with the roadmap commit we just
  # pushed — otherwise the on-disk tasks.toml drifts behind origin and the
  # operator's next edit/merge conflicts. ff-only and best-effort: a skip
  # (dirty/diverged/self-host checkout) logs and never fails the transition.
  @spec sync_local(String.t(), String.t()) :: :ok
  defp sync_local(repo, target) do
    case TargetSync.ff_local(repo, target) do
      :synced ->
        :ok

      {:skipped, reason} ->
        Logger.info("harness roadmap durable: local #{target} not fast-forwarded (#{reason})")
        :ok
    end
  end

  @spec fetch(String.t(), String.t()) :: :ok | {:error, error()}
  defp fetch(repo, target) do
    refspec = "refs/heads/#{target}:refs/remotes/origin/#{target}"

    case Git.run(["fetch", "origin", refspec], repo) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:roadmap_fetch_failed, reason}}
    end
  end

  # Detached at the freshly-fetched origin tip — never a branch the operator's
  # checkout (or a run's retained worktree) might hold, so it never conflicts.
  @spec checkout(String.t(), String.t()) :: {:ok, Worktree.t()} | {:error, error()}
  defp checkout(repo, target) do
    case Worktree.checkout_existing(repo, "origin/" <> target) do
      {:ok, worktree} -> {:ok, worktree}
      {:error, reason} -> {:error, {:roadmap_checkout_failed, reason}}
    end
  end

  # The detached worktree is otherwise clean, so `git add -A` captures exactly
  # rmap's renders (tasks.toml + data.json + ROADMAP.md). A no-op transition
  # leaves nothing staged.
  @spec stage_and_commit(String.t(), String.t()) :: {:ok, :committed | :no_changes} | {:error, error()}
  defp stage_and_commit(path, message) do
    with {:ok, _added} <- Git.run(["add", "-A"], path),
         {:ok, status} <- Git.run(["status", "--porcelain"], path) do
      if String.trim(status) == "", do: {:ok, :no_changes}, else: git_commit(path, message)
    else
      {:error, reason} -> {:error, {:roadmap_stage_failed, reason}}
    end
  end

  @spec git_commit(String.t(), String.t()) :: {:ok, :committed} | {:error, error()}
  defp git_commit(path, message) do
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
      {:error, reason} -> {:error, {:roadmap_commit_failed, reason}}
    end
  end

  # ff-only push of the roadmap commit to the remote target; a non-ff rejection
  # (a concurrent writer landed first) routes to `:retry`, never `--force`.
  @spec push(String.t(), String.t()) :: :ok | :retry | {:error, error()}
  defp push(path, target) do
    with {:ok, head} <- Git.run(["rev-parse", "HEAD"], path),
         {:ok, _output} <- Git.run(["push", "origin", "HEAD:refs/heads/" <> target], path) do
      verify_remote_tip(path, target, String.trim(head))
    else
      {:error, {:git_failed, ["push" | _args], status, output}} ->
        if Git.non_fast_forward?(path, "HEAD", target, status, output),
          do: :retry,
          else: {:error, {:roadmap_push_failed, output}}

      {:error, reason} ->
        {:error, {:roadmap_push_unverified, target, reason}}
    end
  end

  @spec verify_remote_tip(String.t(), String.t(), String.t()) :: :ok | {:error, error()}
  defp verify_remote_tip(path, target, expected) do
    ref = "refs/heads/" <> target

    case Git.run(["ls-remote", "--exit-code", "origin", ref], path) do
      {:ok, output} ->
        case String.split(output, ~r/\s+/, trim: true) do
          [^expected, ^ref] -> :ok
          [actual, ^ref] -> {:error, {:roadmap_push_unverified, target, {:tip_mismatch, expected, actual}}}
          _ -> {:error, {:roadmap_push_unverified, target, {:unexpected_ls_remote, output}}}
        end

      {:error, reason} ->
        {:error, {:roadmap_push_unverified, target, reason}}
    end
  end

  @spec cleanup(Worktree.t()) :: :ok
  defp cleanup(%Worktree{} = worktree) do
    case Worktree.remove(worktree) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness roadmap durable: failed to remove worktree #{worktree.path}: #{inspect(reason)}")

        :ok
    end
  end
end
