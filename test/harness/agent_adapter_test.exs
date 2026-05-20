defmodule Harness.AgentAdapterTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Run

  # A minimal in-test adapter — doubles as live proof the contract is
  # implementable in a handful of lines.
  defmodule EchoAdapter do
    @moduledoc false
    @behaviour AgentAdapter

    @impl AgentAdapter
    def capabilities do
      %Capabilities{session_resume: true, permission_modes: [:autonomous, :plan]}
    end

    @impl AgentAdapter
    def build_command(%Invocation{adapter_opts: opts}) do
      case Keyword.get(opts, :command, :echo) do
        :echo -> {:ok, {"/bin/echo", ["harness-test"], []}}
        :sleep -> {:ok, {"/bin/sleep", ["30"], []}}
        :missing -> {:ok, {"definitely-not-a-real-binary-xyz", [], []}}
      end
    end

    @impl AgentAdapter
    def classify_message({port, {:data, data}}, %Run{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %Run{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl AgentAdapter
    def terminate(%Run{port: port, os_pid: os_pid}) do
      if os_pid do
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end

      close_port(port)
    end

    # Port.close/1 raises if the port has already closed — which races with the
    # killed OS process closing it first. Tolerate that so terminate/1 stays
    # idempotent.
    defp close_port(port) do
      Port.close(port)
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  # Carries only a capability declaration — exercises the false branches of
  # supports?/2 and the build_command error path of invoke/2.
  defmodule MinimalAdapter do
    @moduledoc false
    @behaviour AgentAdapter

    @impl AgentAdapter
    def capabilities, do: %Capabilities{streaming_output: false}

    @impl AgentAdapter
    def build_command(_invocation), do: {:error, :not_implemented}

    @impl AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl AgentAdapter
    def terminate(_run), do: :ok
  end

  defp invocation(adapter_opts \\ []) do
    %Invocation{prompt: "do the task", cwd: "/tmp", task_id: "3", adapter_opts: adapter_opts}
  end

  # Drive a run the way the lifecycle process will: feed every received message
  # through classify_message/2 until the run terminates.
  defp drive(adapter, run, acc \\ []) do
    receive do
      message ->
        case adapter.classify_message(message, run) do
          {:output, data, next_run} -> drive(adapter, next_run, [acc, data])
          {:terminated, _run, status} -> {IO.iodata_to_binary(acc), status}
          {:error, reason, _run} -> flunk("unexpected classify_message error: #{inspect(reason)}")
          :ignore -> drive(adapter, run, acc)
        end
    after
      5_000 -> flunk("run did not terminate within 5s")
    end
  end

  defp await_dead(os_pid, tries \\ 40)
  defp await_dead(_os_pid, 0), do: flunk("OS process was not killed")

  defp await_dead(os_pid, tries) do
    {_output, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    if code == 0 do
      Process.sleep(25)
      await_dead(os_pid, tries - 1)
    else
      :ok
    end
  end

  describe "Capabilities" do
    test "defaults to the conservative baseline" do
      assert %Capabilities{
               session_resume: false,
               permission_modes: [:autonomous],
               streaming_output: true
             } = %Capabilities{}
    end
  end

  describe "Invocation" do
    test "enforces prompt, cwd and task_id" do
      assert_raise ArgumentError, fn -> struct!(Invocation, prompt: "p", cwd: "/tmp") end
    end

    test "defaults the how-to-run fields" do
      invocation = %Invocation{prompt: "p", cwd: "/tmp", task_id: "3"}
      assert invocation.session == nil
      assert invocation.permission_mode == :autonomous
      assert invocation.model == nil
      assert invocation.adapter_opts == []
    end
  end

  describe "Run" do
    test "enforces the harness-owned fields" do
      assert_raise ArgumentError, fn -> struct!(Run, ref: make_ref()) end
    end
  end

  describe "behaviour" do
    test "declares the four adapter callbacks" do
      callbacks = AgentAdapter.behaviour_info(:callbacks)

      for callback <- [
            {:capabilities, 0},
            {:build_command, 1},
            {:classify_message, 2},
            {:terminate, 1}
          ] do
        assert callback in callbacks
      end
    end
  end

  describe "supports?/2" do
    test "reflects the adapter's capability declaration" do
      assert AgentAdapter.supports?(EchoAdapter, :session_resume)
      assert AgentAdapter.supports?(EchoAdapter, :streaming_output)
      assert AgentAdapter.supports?(EchoAdapter, {:permission_mode, :autonomous})
      assert AgentAdapter.supports?(EchoAdapter, {:permission_mode, :plan})

      refute AgentAdapter.supports?(EchoAdapter, {:permission_mode, :unknown})
      refute AgentAdapter.supports?(MinimalAdapter, :session_resume)
      refute AgentAdapter.supports?(MinimalAdapter, :streaming_output)
      assert AgentAdapter.supports?(MinimalAdapter, {:permission_mode, :autonomous})
    end
  end

  describe "build_command/1" do
    test "is pure and returns the spawn recipe without spawning" do
      assert {:ok, {"/bin/echo", ["harness-test"], []}} = EchoAdapter.build_command(invocation())
    end
  end

  describe "invoke/2" do
    test "spawns the agent and captures raw output through to termination" do
      assert {:ok, %Run{} = run} = AgentAdapter.invoke(EchoAdapter, invocation())
      assert run.adapter == EchoAdapter
      assert is_reference(run.ref)
      assert is_port(run.port)
      assert is_integer(run.started_at)
      assert run.adapter_state == nil

      assert {"harness-test\n", 0} = drive(EchoAdapter, run)
    end

    test "returns the adapter's build_command error without spawning" do
      assert {:error, :not_implemented} = AgentAdapter.invoke(MinimalAdapter, invocation())
    end

    test "returns an error when the executable is not on PATH" do
      assert {:error, {:executable_not_found, "definitely-not-a-real-binary-xyz"}} =
               AgentAdapter.invoke(EchoAdapter, invocation(command: :missing))
    end
  end

  describe "terminate/1" do
    test "kills an in-flight run and releases its port" do
      assert {:ok, run} = AgentAdapter.invoke(EchoAdapter, invocation(command: :sleep))
      assert is_integer(run.os_pid)

      assert :ok = EchoAdapter.terminate(run)
      refute Port.info(run.port)
      assert await_dead(run.os_pid) == :ok

      # Idempotent — safe to call on a run that has already ended.
      assert :ok = EchoAdapter.terminate(run)
    end
  end
end
