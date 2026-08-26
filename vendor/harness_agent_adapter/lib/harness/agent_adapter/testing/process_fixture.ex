defmodule Harness.AgentAdapter.Testing.ProcessFixture do
  @moduledoc """
  Throwaway OS processes for adapter tests, plus liveness assertions on them.

  Ships in `lib/` rather than `test/support/` because
  `Harness.AgentAdapter.Testing.ConformanceCase` calls into it: a consumer that
  `use`s the conformance suite against its own adapter compiles only this
  package's `lib/`, so a fixture left behind in `test/support/` would raise
  `UndefinedFunctionError` at run time.

  A stand-in `/bin/sleep` is a faithful substitute for a real coding-agent
  process here: `c:Harness.AgentAdapter.classify_message/2` and
  `c:Harness.AgentAdapter.terminate/1` match port messages and delegate to
  `Harness.AgentAdapter.OSProcess`, so neither one inspects what the process
  actually is.

  Every spawned process is registered for `ExUnit.Callbacks.on_exit/1` cleanup,
  so a test that closes a port without reaping the process still leaves nothing
  behind.

  Requires a running ExUnit test process — the cleanup hook and the flunk on a
  surviving process are both ExUnit-owned.
  """

  alias Harness.AgentAdapter.OSProcess

  @doc """
  Opens a long-lived `/bin/sleep` over a port, registers `on_exit` cleanup, and
  returns `{port, os_pid}`.

  The OS pid is `nil` when the port reports none, which is why callers asserting
  on the pid check `is_integer/1` first.
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

  Polls every 25ms for `tries` attempts (default 40, i.e. a one-second budget).
  Reaping is asynchronous — the kernel may still be tearing the process down
  after `c:Harness.AgentAdapter.terminate/1` has returned — so an assertion on
  process death has to poll rather than read once.
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
