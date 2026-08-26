defmodule Harness.AgentAdapter.OSProcessTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run
  alias Harness.ProcessFixture

  setup do
    previous = Application.get_env(:harness_agent_adapter, :run)
    Application.put_env(:harness_agent_adapter, :run, terminate_grace_ms: 50)

    on_exit(fn ->
      if previous do
        Application.put_env(:harness_agent_adapter, :run, previous)
      else
        Application.delete_env(:harness_agent_adapter, :run)
      end
    end)
  end

  test "default adapter termination gracefully escalates and quiesces the descendant tree" do
    log = Path.join(System.tmp_dir!(), "harness-terminate-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(log) end)

    child_script = """
    trap 'echo child-term >> #{log}' TERM
    sh -c "trap 'echo leaf-term >> #{log}' TERM; while :; do :; done" &
    wait
    """

    root_script = """
    trap 'echo root-term >> #{log}' TERM
    sh -c "$1" &
    wait
    """

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        {:args, ["-c", root_script, "harness-child", child_script]}
      ])

    root = OSProcess.os_pid(port)
    descendants = await_descendants(root, 2)

    run = %Run{ref: make_ref(), adapter: __MODULE__, port: port, os_pid: root, started_at: 0}
    assert OSProcess.kill(run) == :ok

    assert File.read!(log) =~ "root-term"
    assert File.read!(log) =~ "child-term"
    assert File.read!(log) =~ "leaf-term"
    assert ProcessFixture.await_dead(root) == :ok
    for pid <- descendants, do: assert(ProcessFixture.await_dead(pid) == :ok)
  end

  test "tree termination is idempotent for nil and dead pids" do
    assert OSProcess.kill_tree(nil) == :ok
    {_port, os_pid} = ProcessFixture.spawn_sleep()
    assert OSProcess.kill_tree(os_pid) == :ok
    assert OSProcess.kill_tree(os_pid) == :ok
  end

  defp await_descendants(root, count, tries \\ 80)
  defp await_descendants(root, _count, 0), do: flunk("descendants of #{root} never appeared")

  defp await_descendants(root, count, tries) do
    {output, 0} = System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true)

    table =
      Map.new(String.split(output, "\n", trim: true), fn line ->
        [pid, ppid] = String.split(line)
        {String.to_integer(pid), String.to_integer(ppid)}
      end)

    descendants = Enum.filter(Map.keys(table), &descendant?(&1, root, table))

    if length(descendants) < count do
      Process.sleep(10)
      await_descendants(root, count, tries - 1)
    else
      descendants
    end
  end

  defp descendant?(pid, root, table) do
    case Map.get(table, pid) do
      ^root -> true
      nil -> false
      0 -> false
      parent -> descendant?(parent, root, table)
    end
  end
end
