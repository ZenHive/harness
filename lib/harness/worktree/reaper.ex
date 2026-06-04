defmodule Harness.Worktree.Reaper do
  @moduledoc false

  # Same-BEAM crash reaper for harness worktrees (Task 185).
  #
  # The boot-time `Harness.Worktree.Sweeper` reclaims crash-orphaned worktrees
  # ACROSS restarts. This reaper closes the WITHIN-node gap: when a run's
  # gen_statem crashes before it can settle, `Harness.Worktree.finish/3` never
  # runs, and the `cleanup_for_run/2` liveness guard had correctly REFUSED to
  # touch the checkout while the run was live (Task 180). Its worktree dir +
  # `harness/<run-id>` branch would then leak until the next boot. The reaper
  # monitors each tracked run and, on an ABNORMAL `:DOWN`, runs the same reap the
  # Sweeper would — distinguishing a CRASH (reclaim) from a SETTLED run.
  #
  # A run untracks itself at settle (`Harness.Run` settle/2), having already
  # retained-on-failure or removed-on-success its worktree, so a clean exit is
  # already gone from the table when its `:normal` `:DOWN` arrives. The
  # `retained?/1` check is the belt to that suspenders: a crash in the narrow
  # window after the retained marker is written but before untrack is still kept.
  # `cleanup_for_run/2` is idempotent, so a redundant reap (or a race with the
  # boot Sweeper) is a harmless no-op, never an error.

  use GenServer

  alias Harness.Worktree

  require Logger

  @typep tracked :: {run_id :: String.t(), worktree_path :: String.t(), repo :: String.t()}
  @typep state :: %{by_ref: %{reference() => tracked()}, by_run: %{String.t() => reference()}}
  @retry_after_ms 50

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Begins monitoring `run_pid`; an abnormal exit reclaims its leaked worktree+branch.

  Idempotent per `run_id` (a re-track replaces the prior monitor). A no-op when
  the reaper is not running (test envs that don't start it), so the run lifecycle
  never depends on it being up.
  """
  @spec track(pid(), String.t(), String.t(), String.t()) :: :ok
  def track(run_pid, run_id, worktree_path, repo)
      when is_pid(run_pid) and is_binary(run_id) and is_binary(worktree_path) and is_binary(repo) do
    cast({:track, run_pid, run_id, worktree_path, repo})
  end

  @doc """
  Stops monitoring `run_id` — called at settle, once the worktree is finalized.
  """
  @spec untrack(String.t()) :: :ok
  def untrack(run_id) when is_binary(run_id), do: cast({:untrack, run_id})

  @impl GenServer
  @spec init(:ok) :: {:ok, state()}
  def init(:ok), do: {:ok, %{by_ref: %{}, by_run: %{}}}

  @impl GenServer
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:track, run_pid, run_id, worktree_path, repo}, state) do
    state = drop_run(state, run_id)
    ref = Process.monitor(run_pid)

    {:noreply,
     %{
       state
       | by_ref: Map.put(state.by_ref, ref, {run_id, worktree_path, repo}),
         by_run: Map.put(state.by_run, run_id, ref)
     }}
  end

  def handle_cast({:untrack, run_id}, state), do: {:noreply, drop_run(state, run_id)}

  @impl GenServer
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.by_ref, ref) do
      {{run_id, worktree_path, repo}, by_ref} ->
        maybe_reap(run_id, worktree_path, repo, reason, retry?: true)
        {:noreply, %{state | by_ref: by_ref, by_run: Map.delete(state.by_run, run_id)}}

      {nil, _by_ref} ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_reap, run_id, worktree_path, repo, reason}, state) do
    maybe_reap(run_id, worktree_path, repo, reason, retry?: false)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Crash-only reap: a settled run exits `:normal`/`:shutdown` and has already
  # finalized its worktree, so only an abnormal exit reaches the reclaim path —
  # and even then a retained (kept-for-salvage) worktree is left untouched.
  @spec maybe_reap(String.t(), String.t(), String.t(), term(), keyword()) :: :ok
  defp maybe_reap(run_id, worktree_path, repo, reason, opts) do
    cond do
      not crash?(reason) ->
        :ok

      Worktree.retained?(worktree_path) ->
        Logger.info("worktree reaper: run #{run_id} crashed with a retained worktree; keeping #{worktree_path}")
        :ok

      true ->
        Logger.info("worktree reaper: reclaiming crash-orphaned worktree+branch for run #{run_id} (#{inspect(reason)})")
        reap_or_retry(run_id, worktree_path, repo, reason, Keyword.fetch!(opts, :retry?))
    end
  end

  @spec reap_or_retry(String.t(), String.t(), String.t(), term(), boolean()) :: :ok
  defp reap_or_retry(run_id, worktree_path, repo, reason, retry?) do
    case Worktree.cleanup_for_run(repo, run_id) do
      :ok ->
        :ok

      {:error, :live_run} when retry? ->
        Logger.info("worktree reaper: run #{run_id} still registered after crash DOWN; retrying once")
        Process.send_after(self(), {:retry_reap, run_id, worktree_path, repo, reason}, @retry_after_ms)
        :ok

      {:error, :live_run} ->
        :ok
    end
  end

  @spec crash?(term()) :: boolean()
  defp crash?(:normal), do: false
  defp crash?(:shutdown), do: false
  defp crash?({:shutdown, _reason}), do: false
  defp crash?(_reason), do: true

  @spec drop_run(state(), String.t()) :: state()
  defp drop_run(state, run_id) do
    case Map.pop(state.by_run, run_id) do
      {nil, _by_run} ->
        state

      {ref, by_run} ->
        Process.demonitor(ref, [:flush])
        %{state | by_ref: Map.delete(state.by_ref, ref), by_run: by_run}
    end
  end

  @spec cast(term()) :: :ok
  defp cast(message) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, message)
    :ok
  end
end
