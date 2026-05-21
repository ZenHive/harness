defmodule Harness.AgentAdapter.ClaudeTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Run
  alias Harness.GitFixture
  alias Harness.ProcessFixture

  @baseline_argv [
    "-p",
    "--output-format",
    "stream-json",
    "--verbose",
    "--permission-mode",
    "bypassPermissions"
  ]

  defp invocation(attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: "/tmp", task_id: "7"}, attrs)
  end

  defp run_for(port, os_pid) do
    %Run{
      ref: make_ref(),
      adapter: Claude,
      port: port,
      os_pid: os_pid,
      started_at: System.monotonic_time()
    }
  end

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous]
             } = Claude.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless stream-json run for the autonomous baseline" do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation())
      assert argv == @baseline_argv ++ ["do the task"]
    end

    test "passes the model through as --model" do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation(model: "opus"))
      assert argv == @baseline_argv ++ ["--model", "opus", "do the task"]
    end

    test "appends --continue for a :resume session" do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation(session: :resume))
      assert argv == @baseline_argv ++ ["--continue", "do the task"]
    end

    test "omits the resume flag for a fresh run" do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation())
      refute "--continue" in argv
    end

    test "orders model then resume, with the prompt last" do
      assert {:ok, {"claude", argv, []}} =
               Claude.build_command(invocation(model: "opus", session: :resume))

      assert argv == @baseline_argv ++ ["--model", "opus", "--continue", "do the task"]
    end

    test "rejects a permission mode outside its capabilities" do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Claude.build_command(invocation(permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel" do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Claude.build_command(invocation(session: "abc-123"))
    end
  end

  describe "classify_message/2" do
    test "classifies data as output, exit status as termination, the rest as ignore" do
      {port, os_pid} = ProcessFixture.spawn_sleep()
      run = run_for(port, os_pid)

      assert {:output, "chunk", ^run} = Claude.classify_message({port, {:data, "chunk"}}, run)
      assert {:terminated, ^run, 0} = Claude.classify_message({port, {:exit_status, 0}}, run)
      assert :ignore = Claude.classify_message({port, {:other, :event}}, run)
      assert :ignore = Claude.classify_message(:unrelated, run)
    end
  end

  describe "terminate/1" do
    test "kills an in-flight run via the shared OSProcess helper" do
      {port, os_pid} = ProcessFixture.spawn_sleep()
      run = run_for(port, os_pid)

      assert :ok = Claude.terminate(run)
      refute Port.info(port)
      assert ProcessFixture.await_dead(os_pid) == :ok

      # Idempotent — safe on a run that has already ended.
      assert :ok = Claude.terminate(run)
    end
  end

  describe "integration (real claude)" do
    @tag :integration
    test "drives a real claude headless run end to end" do
      if System.find_executable("claude") == nil do
        flunk("""
        `claude` is not on PATH — the Claude Code adapter integration test cannot run.
        Install Claude Code (https://code.claude.com/docs/en/setup), then re-run:
            mix test --include integration test/harness/agent_adapter/claude_test.exs
        """)
      end

      repo = GitFixture.init_repo()
      invocation = %Invocation{prompt: "Reply with exactly the word: pong", cwd: repo, task_id: "7"}

      assert {:ok, outcome} =
               Driver.run(Claude, invocation, total_timeout: 120_000, idle_timeout: 60_000)

      # The adapter's job: spawn, capture raw output, report termination — not
      # judge what claude said. Raw stream-json carries a `type` on every event.
      assert outcome.kind == :exited
      assert outcome.output =~ ~s("type")
    end
  end
end
