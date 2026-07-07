defmodule Harness.Worktree.Sweeper do
  @moduledoc false

  # Boot-time orphan reaper for harness worktrees.
  #
  # A run that crashes hard — the BEAM dies, the machine reboots — never reaches
  # `Harness.Worktree.finish/3`, leaving its worktree directory on disk with no
  # process tracking it. This module sweeps those orphans once at application
  # boot. Within-session crash cleanup is the run lifecycle's own concern; this
  # is the cross-restart safety net.
  #
  # The sweep self-discovers the target repos: a git worktree directory holds a
  # `.git` *file* of the form `gitdir: <repo>/.git/worktrees/<id>`, so the parent
  # repo is recovered without harness having to know it up front.

  alias Harness.Git
  alias Harness.Worktree

  require Logger

  @boot_sweep_exceptions [
    ArgumentError,
    ErlangError,
    File.Error,
    FunctionClauseError,
    MatchError,
    RuntimeError
  ]

  @typedoc "What a sweep did: repos pruned, orphan dirs removed, retained or active dirs kept."
  @type summary :: %{
          pruned: non_neg_integer(),
          removed: [String.t()],
          kept: [String.t()]
        }

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    # reach:disable-next-line fixed_shape_map — standard OTP Supervisor.child_spec/1 literal
    %{id: __MODULE__, start: {Task, :start_link, [__MODULE__, :run, []]}, restart: :transient}
  end

  @doc false
  @spec run() :: :ok
  def run do
    {:ok, summary} = sweep(Worktree.base_dir())
    Logger.info("harness worktree boot sweep: #{inspect(summary)}")
    :ok
  rescue
    error in @boot_sweep_exceptions ->
      Logger.error("harness worktree boot sweep crashed: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Reaps crash-orphaned worktrees under `base_dir`.

  Prunes stale git metadata for every parent repo discovered, then removes each
  orphan worktree directory that lacks the retained-on-failure marker and a live
  active-run marker. Retained worktrees (a human kept one to inspect a failure)
  and active worktrees (a still-running harness process owns them) are left
  untouched.

  Best-effort: a git failure on one repo or directory is logged and skipped, it
  never aborts the sweep. Always returns `{:ok, summary}`.
  """
  @spec sweep(String.t()) :: {:ok, summary()}
  def sweep(base_dir) do
    entries = base_dir |> candidates() |> Enum.map(fn dir -> {dir, parent_repo(dir)} end)
    pruned = entries |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> prune()
    {removed, kept} = reap(entries)
    {:ok, %{pruned: pruned, removed: removed, kept: kept}}
  end

  @spec candidates(String.t()) :: [String.t()]
  defp candidates(base_dir) do
    base_dir
    |> Path.join("**/.git")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
  end

  @spec parent_repo(String.t()) :: String.t() | nil
  # `dir` is a Path.wildcard result under the sweep base, not external input;
  # reading each worktree's .git marker is the sweeper's purpose.
  # sobelow_skip ["Traversal.FileModule"]
  defp parent_repo(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, ".git")),
         "gitdir: " <> gitdir <- String.trim(contents),
         [repo, _id] <- String.split(gitdir, "/.git/worktrees/", parts: 2) do
      repo
    else
      _other -> nil
    end
  end

  @spec prune([String.t()]) :: non_neg_integer()
  defp prune(repos) do
    Enum.count(repos, fn repo ->
      case Git.run(["worktree", "prune"], repo) do
        {:ok, _output} ->
          true

        {:error, reason} ->
          Logger.warning("harness worktree sweep: prune failed for #{repo}: #{inspect(reason)}")
          false
      end
    end)
  end

  @spec reap([{String.t(), String.t() | nil}]) :: {[String.t()], [String.t()]}
  defp reap(entries) do
    Enum.reduce(entries, {[], []}, fn {dir, repo}, {removed, kept} ->
      cond do
        Worktree.retained?(dir) -> {removed, [dir | kept]}
        Worktree.active?(dir) -> {removed, [dir | kept]}
        reap_one(dir, repo) -> {[dir | removed], kept}
        true -> {removed, kept}
      end
    end)
  end

  @spec reap_one(String.t(), String.t() | nil) :: boolean()
  defp reap_one(dir, nil) do
    Logger.warning("harness worktree sweep: #{dir} has no parent repo, leaving it in place")
    false
  end

  defp reap_one(dir, repo) do
    case Git.run(["worktree", "remove", "--force", dir], repo) do
      {:ok, _output} ->
        true

      {:error, reason} ->
        Logger.warning("harness worktree sweep: remove failed for #{dir}: #{inspect(reason)}")
        false
    end
  end
end
