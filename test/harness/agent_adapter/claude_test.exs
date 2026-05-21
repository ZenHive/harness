defmodule Harness.AgentAdapter.ClaudeTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Invocation

  # Claude-specific adapter behaviour. The agent-agnostic contract — invocation,
  # raw-output capture, termination detection, timeout, adapter-level
  # cancellation, and the live end-to-end run — is exercised by the shared
  # conformance suite (`Harness.AgentAdapter.ClaudeConformanceTest`). What stays
  # here is what only Claude does: argv composition, permission-mode mapping,
  # and the `:resume` session sentinel.

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
end
