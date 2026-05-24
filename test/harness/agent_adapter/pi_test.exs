defmodule Harness.AgentAdapter.PiTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Pi

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-pi-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, task_id: "52"}, attrs)
  end

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous]
             } = Pi.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless --mode json run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"pi", argv, []}} = Pi.build_command(invocation(cwd))

      assert argv == ["-p", "--mode", "json", "do the task"]
      assert File.exists?(Path.join(cwd, "AGENTS.md"))
    end

    test "passes the model through as --model", %{cwd: cwd} do
      assert {:ok, {"pi", argv, []}} =
               Pi.build_command(invocation(cwd, model: "anthropic/claude-sonnet-4-6"))

      assert argv == [
               "-p",
               "--mode",
               "json",
               "--model",
               "anthropic/claude-sonnet-4-6",
               "do the task"
             ]
    end

    test "appends --continue for a :resume session", %{cwd: cwd} do
      assert {:ok, {"pi", argv, []}} = Pi.build_command(invocation(cwd, session: :resume))

      assert argv == ["-p", "--mode", "json", "--continue", "do the task"]
    end

    test "omits the resume flag for a fresh run", %{cwd: cwd} do
      assert {:ok, {"pi", argv, []}} = Pi.build_command(invocation(cwd))
      refute "--continue" in argv
    end

    test "orders model then --continue, with the prompt last on a resume", %{cwd: cwd} do
      assert {:ok, {"pi", argv, []}} =
               Pi.build_command(invocation(cwd, model: "anthropic/claude-sonnet-4-6", session: :resume))

      assert argv == [
               "-p",
               "--mode",
               "json",
               "--model",
               "anthropic/claude-sonnet-4-6",
               "--continue",
               "do the task"
             ]
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Pi.build_command(invocation(cwd, permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Pi.build_command(invocation(cwd, session: "abc-123"))
    end
  end
end
