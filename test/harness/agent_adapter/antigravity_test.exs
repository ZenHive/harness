defmodule Harness.AgentAdapter.AntigravityTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @baseline_argv [
    "-p",
    "do the task",
    "--dangerously-skip-permissions"
  ]

  defp invocation(attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: "/tmp", task_id: "26"}, attrs)
  end

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous]
             } = Antigravity.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless run for the autonomous baseline" do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation())
      assert argv == @baseline_argv
    end

    test "rejects any model override" do
      assert {:error, {:unsupported_model, "custom-model"}} =
               Antigravity.build_command(invocation(model: "custom-model"))
    end

    test "appends --continue for a :resume session" do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation(session: :resume))
      assert argv == @baseline_argv ++ ["--continue"]
    end

    test "omits the resume flag for a fresh run" do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation())
      refute "--continue" in argv
    end

    test "rejects a permission mode outside its capabilities" do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Antigravity.build_command(invocation(permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel" do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Antigravity.build_command(invocation(session: "abc-123"))
    end
  end
end
