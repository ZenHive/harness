defmodule Harness.AgentAdapter.AntigravityTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-antigravity-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, task_id: "26"}, attrs)
  end

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode, no worktree isolation" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous],
               worktree_isolation: false
             } = Antigravity.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation(cwd))

      assert argv == [
               "-p",
               RulesInjection.prepend_prompt("do the task"),
               "--dangerously-skip-permissions"
             ]
    end

    test "rejects any model override", %{cwd: cwd} do
      assert {:error, {:unsupported_model, "custom-model"}} =
               Antigravity.build_command(invocation(cwd, model: "custom-model"))
    end

    test "appends --continue for a :resume session", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation(cwd, session: :resume))

      assert argv == [
               "-p",
               RulesInjection.prepend_prompt("do the task"),
               "--dangerously-skip-permissions",
               "--continue"
             ]
    end

    test "omits the resume flag for a fresh run", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation(cwd))
      refute "--continue" in argv
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Antigravity.build_command(invocation(cwd, permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Antigravity.build_command(invocation(cwd, session: "abc-123"))
    end
  end

  describe "worktree isolation" do
    test "documents the agy limitation for dispatch gating" do
      assert Antigravity.worktree_isolation_limitation() =~ "git-common-dir"
    end
  end
end
