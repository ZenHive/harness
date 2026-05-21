defmodule Harness.AgentAdapter.OSProcessTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run
  alias Harness.ProcessFixture

  defp run_for(port, os_pid) do
    %Run{
      ref: make_ref(),
      adapter: __MODULE__,
      port: port,
      os_pid: os_pid,
      started_at: System.monotonic_time()
    }
  end

  describe "os_pid/1" do
    test "returns the OS pid behind a live port" do
      {port, os_pid} = ProcessFixture.spawn_sleep()

      assert is_integer(os_pid)
      assert OSProcess.os_pid(port) == os_pid
    end

    test "returns nil once the port has closed" do
      {port, _os_pid} = ProcessFixture.spawn_sleep()
      OSProcess.close(port)

      assert OSProcess.os_pid(port) == nil
    end
  end

  describe "close/1" do
    test "closes the port and is idempotent" do
      {port, _os_pid} = ProcessFixture.spawn_sleep()

      assert OSProcess.close(port) == :ok
      refute Port.info(port)

      # Idempotent — the killed OS process can close the port first.
      assert OSProcess.close(port) == :ok
    end
  end

  describe "flush/1" do
    test "drains queued port messages from the mailbox" do
      port =
        Port.open({:spawn_executable, "/bin/echo"}, [
          :binary,
          :exit_status,
          :hide,
          {:args, ["hi"]}
        ])

      # Let the data + exit_status messages land in the mailbox.
      Process.sleep(50)

      assert OSProcess.flush(port) == :ok
      refute_received {^port, _message}
    end
  end

  describe "kill/1" do
    test "closes the port, SIGKILLs the OS process, and is idempotent" do
      {port, os_pid} = ProcessFixture.spawn_sleep()
      run = run_for(port, os_pid)

      assert OSProcess.kill(run) == :ok
      refute Port.info(port)
      assert ProcessFixture.await_dead(os_pid) == :ok

      # Idempotent — safe on a run that has already ended.
      assert OSProcess.kill(run) == :ok
    end
  end
end
