defmodule Harness.Run.MemoryGuardTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.OSProcess
  alias Harness.ProcessFixture
  alias Harness.Run.MemoryGuard

  # Spawns `/bin/sh` that forks N real `sleep` children (the trailing `wait`
  # defeats sh's exec-the-last-command optimisation, guaranteeing the shell
  # stays as a parent over genuine child processes — a tree, not one process).
  # Returns the shell's os_pid; on_exit reaps the whole tree.
  defp spawn_tree(children) do
    script = Enum.map_join(1..children, " ", fn _ -> "sleep 60 &" end) <> " wait"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, :hide, {:args, ["-c", script]}])

    os_pid = OSProcess.os_pid(port)
    on_exit(fn -> MemoryGuard.kill_tree(os_pid) end)
    {os_pid, await_children(os_pid, children)}
  end

  # Polls the process table until `os_pid` has at least `count` children, so the
  # asserting test never races the shell's async fork.
  defp await_children(os_pid, count, tries \\ 80)
  defp await_children(os_pid, _count, 0), do: flunk("children of #{os_pid} never appeared")

  defp await_children(os_pid, count, tries) do
    kids = child_pids(os_pid)
    if length(kids) >= count, do: kids, else: Process.sleep(25) && await_children(os_pid, count, tries - 1)
  end

  defp child_pids(os_pid) do
    {out, 0} = System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true)

    for line <- String.split(out, "\n", trim: true),
        [pid, ppid] <- [String.split(line)],
        String.to_integer(ppid) == os_pid,
        do: String.to_integer(pid)
  end

  describe "tree_rss_kb/1" do
    test "is 0 for nil and for a pid no longer in the table" do
      {_port, os_pid} = ProcessFixture.spawn_sleep()
      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      assert ProcessFixture.await_dead(os_pid) == :ok

      assert MemoryGuard.tree_rss_kb(nil) == 0
      assert MemoryGuard.tree_rss_kb(os_pid) == 0
    end

    test "counts the whole tree, not just the root process" do
      {os_pid, children} = spawn_tree(2)

      tree = MemoryGuard.tree_rss_kb(os_pid)
      leaf = MemoryGuard.tree_rss_kb(hd(children))

      # The shell's tree (shell + 2 sleeps) must out-weigh any single leaf —
      # proof the descendant walk sums children, not just the root.
      assert tree > 0
      assert leaf > 0
      assert tree > leaf
    end
  end

  describe "kill_tree/1" do
    test "is a no-op for nil and idempotent on a dead pid" do
      assert MemoryGuard.kill_tree(nil) == :ok
      {_port, os_pid} = ProcessFixture.spawn_sleep()
      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      assert ProcessFixture.await_dead(os_pid) == :ok
      assert MemoryGuard.kill_tree(os_pid) == :ok
    end

    test "reaps the entire descendant tree — no orphan grandchild survives" do
      {os_pid, children} = spawn_tree(2)
      assert length(children) == 2

      MemoryGuard.kill_tree(os_pid)

      assert ProcessFixture.await_dead(os_pid) == :ok
      for child <- children, do: assert(ProcessFixture.await_dead(child) == :ok)
    end
  end
end
