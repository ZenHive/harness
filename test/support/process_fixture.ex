defmodule Harness.ProcessFixture do
  @moduledoc false

  # Test scaffolding for the AgentAdapter / OSProcess / Driver suites: spawns
  # throwaway OS processes over ports and asserts on their liveness. Every
  # spawned process is registered for `on_exit` cleanup, so a test that closes a
  # port without killing the process still leaves nothing behind.

  alias Harness.AgentAdapter.OSProcess

  @doc """
  Opens a long-lived `/bin/sleep` over a port, registers `on_exit` cleanup, and
  returns `{port, os_pid}`.
  """
  @spec spawn_sleep() :: {port(), non_neg_integer() | nil}
  def spawn_sleep do
    port =
      Port.open({:spawn_executable, "/bin/sleep"}, [
        :binary,
        :exit_status,
        :hide,
        {:args, ["30"]}
      ])

    os_pid = OSProcess.os_pid(port)
    ExUnit.Callbacks.on_exit(fn -> kill(os_pid) end)
    {port, os_pid}
  end

  @doc """
  Blocks until `os_pid` is no longer alive, flunking if it stays up past the
  retry budget.
  """
  @spec await_dead(non_neg_integer(), non_neg_integer()) :: :ok
  def await_dead(os_pid, tries \\ 40)

  def await_dead(os_pid, 0), do: ExUnit.Assertions.flunk("OS process #{os_pid} was not killed")

  def await_dead(os_pid, tries) do
    if alive?(os_pid) do
      Process.sleep(25)
      await_dead(os_pid, tries - 1)
    else
      :ok
    end
  end

  @spec alive?(non_neg_integer()) :: boolean()
  defp alive?(os_pid) do
    {_output, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    code == 0
  end

  @spec kill(non_neg_integer() | nil) :: :ok
  defp kill(nil), do: :ok

  defp kill(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end
end
