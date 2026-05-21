defmodule Harness.AgentAdapter.CursorTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Invocation

  # Cursor-specific adapter behaviour. The agent-agnostic contract — invocation,
  # raw-output capture, termination detection, timeout, adapter-level
  # cancellation, and the live end-to-end run — is exercised by the shared
  # conformance suite (`Harness.AgentAdapter.CursorConformanceTest`). What stays
  # here is what only Cursor does: argv composition, the `--force --trust`
  # autonomous mapping, and the `:resume` session sentinel.

  @baseline_argv [
    "-p",
    "--output-format",
    "stream-json",
    "--force",
    "--trust"
  ]

  defp invocation(attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: "/tmp", task_id: "13"}, attrs)
  end

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous]
             } = Cursor.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless stream-json run for the autonomous baseline" do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation())
      assert argv == @baseline_argv ++ ["do the task"]
    end

    test "maps :autonomous to --force --trust" do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation())
      assert "--force" in argv
      assert "--trust" in argv
    end

    test "passes the model through as --model" do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation(model: "sonnet-4"))
      assert argv == @baseline_argv ++ ["--model", "sonnet-4", "do the task"]
    end

    test "appends --continue for a :resume session" do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation(session: :resume))
      assert argv == @baseline_argv ++ ["--continue", "do the task"]
    end

    test "omits the resume flag for a fresh run" do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation())
      refute "--continue" in argv
    end

    test "orders model then resume, with the prompt last" do
      assert {:ok, {"cursor-agent", argv, []}} =
               Cursor.build_command(invocation(model: "sonnet-4", session: :resume))

      assert argv == @baseline_argv ++ ["--model", "sonnet-4", "--continue", "do the task"]
    end

    test "rejects a permission mode outside its capabilities" do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Cursor.build_command(invocation(permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel" do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Cursor.build_command(invocation(session: "abc-123"))
    end
  end
end
