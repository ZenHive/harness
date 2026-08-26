defmodule Harness.AgentAdapter.OSProcess do
  @moduledoc """
  Shared lifecycle helpers for the OS process tree behind an adapter's OTP port.

  An adapter spawns its agent's headless CLI as an OS process connected to an
  OTP port (`Harness.AgentAdapter.invoke/2`). This module is the small,
  idempotent toolkit for the rest of that lifecycle — reading the OS pid,
  closing the port, draining stranded messages, and killing a run outright — so
  every adapter shares one correct implementation instead of re-deriving the
  `Port`/`kill` plumbing.

  Termination is synchronous and idempotent: the complete descendant tree gets
  SIGTERM, a bounded grace period to flush output, then SIGKILL if necessary.
  The default grace period is 1,000 ms and is configurable as
  `config :harness_agent_adapter, :run, terminate_grace_ms: milliseconds`.
  Returning from `kill/1` or `kill_tree/1` means the captured tree is quiescent
  (or the post-SIGKILL reap window elapsed — an uninterruptible descendant is
  left to the kernel and the host application's worktree sweeper).
  """

  alias Harness.AgentAdapter.Run

  @default_grace_ms 1_000
  @reap_wait_ms 5_000
  @poll_ms 10

  @typep ps_table :: %{non_neg_integer() => {non_neg_integer(), String.t()}}

  @doc """
  The OS process id behind `port`, or `nil` once the port has closed.
  """
  @spec os_pid(port()) :: non_neg_integer() | nil
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  @doc """
  Closes `port`, tolerating a port that has already closed.

  Idempotent: `Port.close/1` raises `ArgumentError` on an already-closed port,
  which races with the killed OS process closing it first — that race is
  swallowed.
  """
  @spec close(port()) :: :ok
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Drains any `{port, _}` messages still queued in the caller's mailbox.

  Called after a kill so stale port output never leaks into a later `receive`.
  """
  @spec flush(port()) :: :ok
  def flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  @doc """
  Terminates an in-flight run's complete process tree, closes its port, and
  drains any leftover port messages.

  Signals **before** closing the port: closing a `:spawn_executable` port reaps
  the OS process, after which the recorded `os_pid` may be recycled to an
  unrelated process — a `kill` landing then would hit the wrong target. With the
  port still open the pid is guaranteed to still name this run's process.

  Idempotent — safe to call on a run that has already ended. This is the default
  implementation an adapter's `c:Harness.AgentAdapter.terminate/1` delegates to.
  """
  @spec kill(Run.t()) :: :ok
  def kill(%Run{port: port, os_pid: os_pid}) do
    kill_tree(os_pid)
    close(port)
    flush(port)
  end

  @doc """
  Terminates an OS process tree with SIGTERM, bounded grace, then SIGKILL.

  The call waits until every process captured before termination is gone, so a
  caller may safely tear down or reuse the run's worktree after it returns.
  """
  @spec kill_tree(non_neg_integer() | nil) :: :ok
  def kill_tree(nil), do: :ok

  def kill_tree(os_pid) when is_integer(os_pid) do
    first = descendants(ps_table(), os_pid)
    signal(first, "-TERM")
    await_quiescence(first, monotonic_ms() + terminate_grace_ms())
    remaining = remaining_tree(os_pid, first)
    signal(Enum.reverse(remaining), "-KILL")
    await_quiescence(remaining, monotonic_ms() + @reap_wait_ms)
    :ok
  end

  @doc """
  SIGKILLs `os_pid` directly. Prefer `kill_tree/1` for lifecycle teardown.

  Fire-and-forget: a pid that already exited makes `kill(1)` fail quietly.
  """
  @spec sigkill(non_neg_integer()) :: :ok
  def sigkill(os_pid) when is_integer(os_pid), do: signal([os_pid], "-KILL")

  @spec terminate_grace_ms() :: non_neg_integer()
  defp terminate_grace_ms do
    :harness_agent_adapter
    |> Application.get_env(:run, [])
    |> Keyword.get(:terminate_grace_ms, @default_grace_ms)
  end

  # Re-walk after the SIGTERM grace window so a child forked during grace, or a
  # survivor reparented to init after the root died, is still in the SIGKILL set.
  @spec remaining_tree(non_neg_integer(), [non_neg_integer()]) :: [non_neg_integer()]
  defp remaining_tree(root, original) do
    table = ps_table()

    case descendants(table, root) do
      [] ->
        original
        |> Enum.filter(&Map.has_key?(table, &1))
        |> Enum.flat_map(&descendants(table, &1))
        |> Enum.uniq()

      tree ->
        tree
    end
  end

  @spec await_quiescence([non_neg_integer()], integer()) :: [non_neg_integer()]
  defp await_quiescence([], _deadline), do: []

  defp await_quiescence(pids, deadline) do
    table = ps_table()
    survivors = Enum.filter(pids, &Map.has_key?(table, &1))

    cond do
      survivors == [] ->
        []

      monotonic_ms() >= deadline ->
        survivors

      true ->
        Process.sleep(@poll_ms)
        await_quiescence(survivors, deadline)
    end
  end

  @spec signal([non_neg_integer()], String.t()) :: :ok
  defp signal([], _name), do: :ok

  defp signal(pids, name) do
    args = [name | Enum.map(pids, &Integer.to_string/1)]
    System.cmd("kill", args, stderr_to_stdout: true)
    :ok
  end

  @spec ps_table() :: ps_table()
  defp ps_table do
    case System.cmd("ps", ["-axo", "pid=,ppid=,stat="], stderr_to_stdout: true) do
      {output, 0} ->
        Enum.reduce(String.split(output, "\n", trim: true), %{}, &parse_ps_line/2)

      _other ->
        %{}
    end
  rescue
    ErlangError -> %{}
  end

  @spec parse_ps_line(String.t(), ps_table()) :: ps_table()
  defp parse_ps_line(line, table) do
    case String.split(line) do
      [pid, ppid, stat] ->
        if String.starts_with?(stat, "Z") do
          table
        else
          Map.put(table, String.to_integer(pid), {String.to_integer(ppid), stat})
        end

      _other ->
        table
    end
  end

  @spec descendants(ps_table(), non_neg_integer()) :: [non_neg_integer()]
  defp descendants(table, root) do
    children =
      Enum.group_by(
        table,
        fn {_pid, {ppid, _stat}} -> ppid end,
        fn {pid, _details} -> pid end
      )

    if Map.has_key?(table, root), do: collect([root], children, []), else: []
  end

  @spec collect([non_neg_integer()], map(), [non_neg_integer()]) :: [non_neg_integer()]
  defp collect([], _children, found), do: Enum.reverse(found)

  defp collect([pid | rest], children, found) do
    collect(rest ++ Map.get(children, pid, []), children, [pid | found])
  end

  @spec monotonic_ms() :: integer()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
