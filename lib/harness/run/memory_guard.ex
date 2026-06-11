defmodule Harness.Run.MemoryGuard do
  @moduledoc """
  Mechanical resident-memory sampling and force-kill for a spawned run's OS
  process *tree* — the Port'd agent CLI plus every descendant it forks,
  including the `check_command` (`mix`/`cargo`/…) the reviewer AI runs itself.

  `Harness.Run`'s per-run memory watchdog samples `tree_rss_kb/1` on a timer; a
  tree past its configured ceiling is `kill_tree/1`'d whole and the run settles
  `:failed`. This exists because a single runaway project check OOM'd the host
  twice on 2026-06-04 (an "onchain" `mix` task ballooned to ~27 GB — kernel
  watchdog panic + jetsam): `Harness.AgentAdapter.OSProcess.kill/1` SIGKILLs
  only the immediate pid and orphans the grandchild that actually held the RAM.

  Mechanical substrate only — `ps`/`kill`, no judgment, no output parsing. RSS
  is read from `ps -o rss=`, reported in KiB on macOS and Linux alike.

  ## Aggregate pressure (the companion bound)

  The per-run cap stops one tree; it does not stop N concurrent trees from
  summing past host RAM. The effective concurrency ceiling is the sum of the
  per-project `project_<name>` Oban queue limits (open-source Oban has no global
  cap). Keep `mem_threshold_kb × that-sum` comfortably under host memory — the
  per-run cap is the runaway backstop, the queue limits are the steady-state
  bound.

  `host_rss_kb/0` + `host_total_kb/0` are the substrate for the aggregate
  companion to the per-run cap: `Harness.Run.Worker`'s node-pressure admission
  gate (Task 202) samples `host_rss_kb/0` and snoozes a NEW run when it is over a
  configurable high-water mark (defaulting to a fraction of `host_total_kb/0`),
  so well-behaved concurrent trees cannot collectively OOM the host.
  """

  alias Harness.AgentAdapter.OSProcess

  @typep ps_row :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Total resident memory (KiB) of `os_pid` and every descendant process.

  Returns 0 for `nil` or a pid no longer in the process table — a dead or
  never-spawned agent contributes nothing.
  """
  @spec tree_rss_kb(non_neg_integer() | nil) :: non_neg_integer()
  def tree_rss_kb(nil), do: 0

  def tree_rss_kb(os_pid) when is_integer(os_pid) do
    table = ps_table()

    table
    |> descendants(os_pid)
    |> Enum.reduce(0, fn pid, sum -> sum + rss_of(table, pid) end)
  end

  @doc """
  SIGKILLs `os_pid` and every descendant, reaping the whole tree so a leaked
  grandchild (`mix`/`beam.smp`) cannot survive the run's teardown.

  Idempotent and safe on an already-dead pid; a no-op for `nil`. Uses a fresh
  process-table snapshot so descendants forked since the last sample are caught.
  """
  @spec kill_tree(non_neg_integer() | nil) :: :ok
  def kill_tree(nil), do: :ok

  def kill_tree(os_pid) when is_integer(os_pid) do
    ps_table()
    |> descendants(os_pid)
    |> Enum.each(&OSProcess.sigkill/1)
  end

  @doc """
  Total resident memory (KiB) summed across every process in the host table —
  the aggregate-pressure sample feeding the node-pressure admission gate (Task
  202). Mechanical sum of `ps -o rss=`; 0 when `ps` is unavailable.
  """
  @spec host_rss_kb() :: non_neg_integer()
  def host_rss_kb do
    Enum.reduce(ps_table(), 0, fn {_pid, {_ppid, rss}}, sum -> sum + rss end)
  end

  @doc """
  Total physical RAM (KiB) of the host, or 0 when it cannot be determined.

  Mechanical probe: `sysctl hw.memsize` on macOS, `/proc/meminfo` on Linux. Used
  only to derive a headroom-leaving default high-water mark for the node-pressure
  gate; 0 on any other platform or read failure, which makes the gate fail open
  (admit) rather than deadlock dispatch.
  """
  @spec host_total_kb() :: non_neg_integer()
  def host_total_kb do
    case :os.type() do
      {:unix, :darwin} -> sysctl_memsize_kb()
      {:unix, _other} -> meminfo_total_kb()
      _other -> 0
    end
  end

  @spec sysctl_memsize_kb() :: non_neg_integer()
  defp sysctl_memsize_kb do
    with {out, 0} <- System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true),
         {bytes, _rest} <- Integer.parse(String.trim(out)) do
      div(bytes, 1024)
    else
      _other -> 0
    end
  end

  @spec meminfo_total_kb() :: non_neg_integer()
  defp meminfo_total_kb do
    with {:ok, contents} <- File.read("/proc/meminfo"),
         [_line, kb] <- Regex.run(~r/MemTotal:\s+(\d+)/, contents) do
      String.to_integer(kb)
    else
      _other -> 0
    end
  end

  # Process table: pid => {ppid, rss_kb}. Empty map if `ps` is unavailable.
  @spec ps_table() :: %{non_neg_integer() => ps_row()}
  defp ps_table do
    case System.cmd("ps", ["-axo", "pid=,ppid=,rss="], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.reduce(%{}, &parse_ps_line/2)
      _ -> %{}
    end
  end

  @spec parse_ps_line(String.t(), %{non_neg_integer() => ps_row()}) :: %{non_neg_integer() => ps_row()}
  defp parse_ps_line(line, acc) do
    with [p, pp, r] <- String.split(line),
         {pid, ""} <- Integer.parse(p),
         {ppid, ""} <- Integer.parse(pp),
         {rss, ""} <- Integer.parse(r) do
      Map.put(acc, pid, {ppid, rss})
    else
      _ -> acc
    end
  end

  # `root` and every transitive child present in `table`, root first. Returns []
  # when `root` has already left the table (process trees are acyclic, so the
  # breadth-first walk always terminates).
  @spec descendants(%{non_neg_integer() => ps_row()}, non_neg_integer()) :: [non_neg_integer()]
  defp descendants(table, root) do
    if Map.has_key?(table, root), do: collect([root], children_index(table), []), else: []
  end

  @spec children_index(%{non_neg_integer() => ps_row()}) :: %{non_neg_integer() => [non_neg_integer()]}
  defp children_index(table) do
    Enum.reduce(table, %{}, fn {pid, {ppid, _rss}}, idx -> Map.update(idx, ppid, [pid], &[pid | &1]) end)
  end

  @spec collect([non_neg_integer()], %{non_neg_integer() => [non_neg_integer()]}, [non_neg_integer()]) ::
          [non_neg_integer()]
  defp collect([], _children, acc), do: Enum.reverse(acc)

  defp collect([pid | rest], children, acc) do
    collect(rest ++ Map.get(children, pid, []), children, [pid | acc])
  end

  @spec rss_of(%{non_neg_integer() => ps_row()}, non_neg_integer()) :: non_neg_integer()
  defp rss_of(table, pid) do
    case Map.get(table, pid) do
      {_ppid, rss} -> rss
      nil -> 0
    end
  end
end
