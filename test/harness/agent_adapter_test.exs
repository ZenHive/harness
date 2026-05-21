defmodule Harness.AgentAdapterTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Run
  alias Harness.FakeAdapter
  alias Harness.ProcessFixture

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
      assert AgentAdapter.supports?(FakeAdapter, :session_resume)
      assert AgentAdapter.supports?(FakeAdapter, :streaming_output)
      assert AgentAdapter.supports?(FakeAdapter, {:permission_mode, :autonomous})
      assert AgentAdapter.supports?(FakeAdapter, {:permission_mode, :plan})

      refute AgentAdapter.supports?(FakeAdapter, {:permission_mode, :unknown})
      refute AgentAdapter.supports?(MinimalAdapter, :session_resume)
      refute AgentAdapter.supports?(MinimalAdapter, :streaming_output)
      assert AgentAdapter.supports?(MinimalAdapter, {:permission_mode, :autonomous})
    end
  end

  describe "build_command/1" do
    test "is pure and returns the spawn recipe without spawning" do
      assert {:ok, {"/bin/echo", ["harness-test"], []}} = FakeAdapter.build_command(invocation())
    end
  end

  describe "invoke/2" do
    test "spawns the agent and captures raw output through to termination" do
      assert {:ok, %Run{} = run} = AgentAdapter.invoke(FakeAdapter, invocation())
      assert run.adapter == FakeAdapter
      assert is_reference(run.ref)
      assert is_port(run.port)
      assert is_integer(run.started_at)
      assert run.adapter_state == nil

      assert {"harness-test\n", 0} = drive(FakeAdapter, run)
    end

    test "returns the adapter's build_command error without spawning" do
      assert {:error, :not_implemented} = AgentAdapter.invoke(MinimalAdapter, invocation())
    end

    test "returns an error when the executable is not on PATH" do
      assert {:error, {:executable_not_found, "definitely-not-a-real-binary-xyz"}} =
               AgentAdapter.invoke(FakeAdapter, invocation(command: :missing))
    end
  end

  describe "terminate/1" do
    test "kills an in-flight run and releases its port" do
      assert {:ok, run} = AgentAdapter.invoke(FakeAdapter, invocation(command: :sleep))
      assert is_integer(run.os_pid)

      assert :ok = FakeAdapter.terminate(run)
      refute Port.info(run.port)
      assert ProcessFixture.await_dead(run.os_pid) == :ok

      # Idempotent — safe to call on a run that has already ended.
      assert :ok = FakeAdapter.terminate(run)
    end
  end
end
