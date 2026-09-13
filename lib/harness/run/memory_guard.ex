defmodule Harness.Run.MemoryGuard do
  @moduledoc """
  Mechanical resident-memory sampling for a spawned run's OS
  process *tree* — the Port'd agent CLI plus every descendant it forks,
  including the `check_command` (`mix`/`cargo`/…) the reviewer AI runs itself.

  `Harness.Run`'s per-run memory watchdog samples `tree_rss_kb/1` on a timer; a
  tree past its configured ceiling is `kill_tree/1`'d whole and the run settles
  `:failed`. This exists because a single runaway project check OOM'd the host
  twice on 2026-06-04 (an "onchain" `mix` task ballooned to ~27 GB — kernel
  watchdog panic + jetsam). Process-tree termination is owned by the shared
  `Harness.AgentAdapter.OSProcess` lifecycle surface.

  Mechanical substrate only — `ps`/`kill`, no judgment, no output parsing. RSS
  is read from `ps -o rss=`, reported in KiB on macOS and Linux alike.

  ## Aggregate pressure (the companion bound)

  The per-run cap stops one tree; it does not stop N concurrent trees from
  summing past host RAM. The effective concurrency ceiling is the sum of the
  per-project `project_<name>` Oban queue limits (open-source Oban has no global
  cap). Keep `mem_threshold_kb × that-sum` comfortably under host memory — the
  per-run cap is the runaway backstop, the queue limits are the steady-state
  bound.

  `host_available_kb/0` reads Linux `MemAvailable`, the kernel's estimate of
  memory allocatable without swapping, including reclaimable cache. The worker
  snoozes NEW admission at or below a configurable headroom reserve (default:
  10% of `host_total_kb/0`). Unavailable samples admit, including on non-Linux
  platforms. This is a host-wide pressure backstop, not a per-tenant budget.

  `host_rss_kb/0` is NOT a memory-pressure measure: it double-counts shared
  pages across processes and is not the admission gate's input.
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
  Terminates `os_pid` and every descendant through the shared lifecycle helper.

  Idempotent and safe on an already-dead pid; a no-op for `nil`. The helper
  performs graceful escalation and waits for tree quiescence.
  """
  @spec kill_tree(non_neg_integer() | nil) :: :ok
  def kill_tree(os_pid), do: OSProcess.kill_tree(os_pid)

  @doc """
  Total resident memory (KiB) summed across every process in the host table —
  a diagnostic sum that double-counts shared pages, not a pressure measure or
  admission-gate input. Returns 0 when `ps` is unavailable.
  """
  @spec host_rss_kb() :: non_neg_integer()
  def host_rss_kb do
    Enum.reduce(ps_table(), 0, fn {_pid, {_ppid, rss}}, sum -> sum + rss end)
  end

  @doc """
  Available host memory (KiB), or `{:error, :unavailable}` when it cannot be read.

  Reads Linux `/proc/meminfo`'s `MemAvailable`; zero is a valid exhausted sample.
  Other platforms fail open. Options `:os_type` and `:meminfo_reader` permit
  injecting the platform and a zero-arity file reader at the I/O boundary.
  """
  @spec host_available_kb(keyword()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def host_available_kb(opts \\ []) do
    case Keyword.get_lazy(opts, :os_type, &:os.type/0) do
      {:unix, :linux} ->
        reader = Keyword.get(opts, :meminfo_reader, fn -> File.read("/proc/meminfo") end)

        with {:ok, contents} <- reader.(),
             [_line, kb] <- Regex.run(~r/^MemAvailable:[ \t]+(\d+)[ \t]+kB[ \t]*$/m, contents) do
          {:ok, String.to_integer(kb)}
        else
          _other -> {:error, :unavailable}
        end

      _other ->
        {:error, :unavailable}
    end
  end

  @doc """
  Total physical RAM (KiB) of the host, or 0 when it cannot be determined.

  Mechanical probe: `sysctl hw.memsize` on macOS, `/proc/meminfo` on Linux. Used
  only to derive the default low-water headroom reserve for the node-pressure
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
  rescue
    # System.cmd raises ErlangError when the OS spawn fails (a dead
    # `erl_child_setup` makes every spawn_executable fail :enoent node-wide).
    # `ps` unavailable means an empty table, per this function's contract — never
    # a raise that crashes the per-run memory watchdog's gen_statem.
    ErlangError -> %{}
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
