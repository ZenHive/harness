defmodule Harness.AgentAdapter.DriverTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run
  alias Harness.FakeAdapter
  alias Harness.ProcessFixture

  # Classifies the first data chunk as a port error — exercises the driver's
  # {:error, _, _} branch, which FakeAdapter never reaches.
  defmodule ErrorClassifyAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.OSProcess

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(_invocation), do: {:ok, {"/bin/echo", ["x"], []}}

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, _data}}, %Run{port: port} = run), do: {:error, :classified_failure, run}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%Run{} = run), do: OSProcess.kill(run)
  end

  defp invocation(command) do
    %Invocation{prompt: "p", cwd: "/tmp", task_id: "7", adapter_opts: [command: command]}
  end

  describe "run/3 — completion" do
    test "captures raw output and reports a clean exit" do
      assert {:ok, %Outcome{} = outcome} =
               Driver.run(FakeAdapter, invocation(:echo), total_timeout: 10_000, idle_timeout: 5_000)

      assert outcome.kind == :exited
      assert outcome.exit_status == 0
      assert outcome.output == "harness-test\n"
      assert %Run{} = outcome.run
    end

    test "carries a non-zero exit status without treating it as failure" do
      assert {:ok, %Outcome{kind: :exited, exit_status: 3}} =
               Driver.run(FakeAdapter, invocation(:exit_code),
                 total_timeout: 10_000,
                 idle_timeout: 5_000
               )
    end

    test "ignores foreign messages already in the mailbox" do
      send(self(), {:not, :a, :port, :message})

      assert {:ok, %Outcome{kind: :exited}} =
               Driver.run(FakeAdapter, invocation(:echo), total_timeout: 10_000, idle_timeout: 5_000)
    end

    test "surfaces a port error classified mid-run" do
      assert {:ok, %Outcome{kind: {:error, :classified_failure}}} =
               Driver.run(ErrorClassifyAdapter, invocation(:echo),
                 total_timeout: 10_000,
                 idle_timeout: 5_000
               )
    end
  end

  describe "run/3 — timeouts" do
    test "kills a run that emits nothing within the idle window" do
      assert {:ok, %Outcome{kind: {:timed_out, :idle}} = outcome} =
               Driver.run(FakeAdapter, invocation(:sleep), total_timeout: 10_000, idle_timeout: 150)

      assert outcome.exit_status == nil
      assert ProcessFixture.await_dead(outcome.run.os_pid) == :ok
    end

    test "kills a run that exceeds the total budget even while emitting" do
      assert {:ok, %Outcome{kind: {:timed_out, :total}} = outcome} =
               Driver.run(FakeAdapter, invocation(:flood), total_timeout: 300, idle_timeout: 10_000)

      assert outcome.output =~ "tick"
      assert ProcessFixture.await_dead(outcome.run.os_pid) == :ok
    end

    test "resets the idle window on each output chunk" do
      # :burst pauses 200ms between chunks and runs ~400ms overall; a 350ms idle
      # window only survives to completion if every chunk resets it.
      assert {:ok, %Outcome{kind: :exited} = outcome} =
               Driver.run(FakeAdapter, invocation(:burst), total_timeout: 10_000, idle_timeout: 350)

      assert outcome.output =~ "one"
      assert outcome.output =~ "three"
    end
  end

  describe "run/3 — spawn failure" do
    test "returns the invoke error when the executable is not on PATH" do
      assert {:error, {:executable_not_found, "definitely-not-a-real-binary-xyz"}} =
               Driver.run(FakeAdapter, invocation(:missing))
    end
  end

  describe "run/3 — :on_spawn hook" do
    test "invokes the hook exactly once with the run handle" do
      # The hook captures into an Agent, not the caller's mailbox — the driver's
      # own receive loop runs in the caller and would consume a sent message.
      {:ok, agent} = Agent.start_link(fn -> [] end)

      assert {:ok, %Outcome{kind: :exited}} =
               Driver.run(FakeAdapter, invocation(:echo),
                 total_timeout: 10_000,
                 idle_timeout: 5_000,
                 on_spawn: fn run -> Agent.update(agent, &[run | &1]) end
               )

      assert [%Run{}] = Agent.get(agent, & &1)
    end

    test "a raising hook does not abort the run" do
      assert {:ok, %Outcome{kind: :exited, exit_status: 0}} =
               Driver.run(FakeAdapter, invocation(:echo),
                 total_timeout: 10_000,
                 idle_timeout: 5_000,
                 on_spawn: fn _run -> raise "boom" end
               )
    end

    test "a throwing hook does not abort the run" do
      assert {:ok, %Outcome{kind: :exited, exit_status: 0}} =
               Driver.run(FakeAdapter, invocation(:echo),
                 total_timeout: 10_000,
                 idle_timeout: 5_000,
                 on_spawn: fn _run -> throw(:boom) end
               )
    end

    test "is not invoked when the agent fails to spawn" do
      parent = self()

      assert {:error, {:executable_not_found, _}} =
               Driver.run(FakeAdapter, invocation(:missing), on_spawn: fn run -> send(parent, {:spawned, run}) end)

      refute_received {:spawned, _}
    end
  end

  describe "run/3 — configuration" do
    test "falls back to :harness, :run config when no options are given" do
      Application.put_env(:harness, :run, total_timeout: 10_000, idle_timeout: 150)
      on_exit(fn -> Application.delete_env(:harness, :run) end)

      assert {:ok, %Outcome{kind: {:timed_out, :idle}}} =
               Driver.run(FakeAdapter, invocation(:sleep))
    end

    test "options override the configured timeouts" do
      Application.put_env(:harness, :run, total_timeout: 10_000, idle_timeout: 10_000)
      on_exit(fn -> Application.delete_env(:harness, :run) end)

      assert {:ok, %Outcome{kind: {:timed_out, :idle}}} =
               Driver.run(FakeAdapter, invocation(:sleep), idle_timeout: 150)
    end
  end
end
