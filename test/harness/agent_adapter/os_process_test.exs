defmodule Harness.AgentAdapter.OSProcessTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run
  alias Harness.ProcessFixture

  @grace_ms 50
  @startup_timeout_ms 2_000

  setup do
    previous = Application.get_env(:harness_agent_adapter, :run, [])
    Application.put_env(:harness_agent_adapter, :run, Keyword.put(previous, :terminate_grace_ms, @grace_ms))

    on_exit(fn -> Application.put_env(:harness_agent_adapter, :run, previous) end)
    :ok
  end

  test "default adapter termination gracefully escalates and quiesces the descendant tree" do
    log = Path.join(System.tmp_dir!(), "harness-terminate-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(log) end)

    {port, root, _cleanup} = spawn_tree(log)
    descendants = await_descendants(root, 2)

    run = %Run{ref: make_ref(), adapter: __MODULE__, port: port, os_pid: root, started_at: 0}
    started = System.monotonic_time(:millisecond)
    assert OSProcess.kill(run) == :ok
    elapsed = System.monotonic_time(:millisecond) - started

    # TERM-trapping processes survive SIGTERM, so the grace window must elapse
    # before SIGKILL. Immediate SIGKILL would return in a handful of ms.
    assert elapsed >= @grace_ms - 10

    assert File.read!(log) =~ "root-term"
    assert File.read!(log) =~ "child-term"
    assert File.read!(log) =~ "leaf-term"
    refute_os_alive(root)
    for pid <- descendants, do: refute_os_alive(pid)
  end

  test "fixture cleanup reaps the tree when an assertion interrupts termination" do
    log = Path.join(System.tmp_dir!(), "harness-cleanup-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(log) end)
    {_port, root, cleanup} = spawn_tree(log)
    descendants = await_descendants(root, 2)

    assert_raise ExUnit.AssertionError, ~r/interrupted before termination/, fn ->
      try do
        flunk("interrupted before termination")
      after
        cleanup.()
      end
    end

    for pid <- [root | descendants], do: ProcessFixture.await_dead(pid)
    refute File.exists?(log <> ".pids")
    assert cleanup.() == :ok
  end

  test "tree termination is idempotent for nil and dead pids" do
    assert OSProcess.kill_tree(nil) == :ok
    {_port, os_pid} = ProcessFixture.spawn_sleep()
    assert OSProcess.kill_tree(os_pid) == :ok
    assert OSProcess.kill_tree(os_pid) == :ok
  end

  @spec spawn_tree(String.t()) :: {port(), pos_integer(), (-> :ok)}
  defp spawn_tree(log) do
    pids = log <> ".pids"
    cleanup = fn -> cleanup_tree(pids) end
    on_exit(cleanup)

    child_script = """
    echo $$ >> #{pids}
    trap 'echo child-term >> #{log}' TERM
    sh -c 'echo $$ >> #{pids}; trap "echo leaf-term >> #{log}" TERM; echo ready; while :; do :; done' &
    wait
    """

    root_script = """
    echo $$ >> #{pids}
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

    assert_receive {^port, {:data, "ready\n"}}, @startup_timeout_ms
    {port, OSProcess.os_pid(port), cleanup}
  end

  # Independent of OSProcess.kill/1: failure of the operation under test must
  # not leave its TERM-trapping fixture spinning after ExUnit exits the test.
  @spec cleanup_tree(String.t()) :: :ok
  defp cleanup_tree(path) do
    case File.read(path) do
      {:ok, contents} ->
        for pid <- contents |> String.split() |> Enum.reverse() do
          System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
        end

      {:error, :enoent} ->
        :ok
    end

    File.rm(path)
    :ok
  end

  @spec await_descendants(pos_integer(), non_neg_integer(), non_neg_integer()) :: [pos_integer()]
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

  @spec descendant?(pos_integer(), pos_integer(), map()) :: boolean()
  defp descendant?(pid, root, table) do
    case Map.get(table, pid) do
      ^root -> true
      nil -> false
      0 -> false
      parent -> descendant?(parent, root, table)
    end
  end

  @spec refute_os_alive(pos_integer()) :: true
  defp refute_os_alive(pid) do
    {_output, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    assert code != 0, "expected pid #{pid} to be dead once kill/1 returned"
  end
end
