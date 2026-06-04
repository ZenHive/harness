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
    test "declares resume + streaming output, autonomous-only permission mode, and worktree isolation" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous],
               worktree_isolation: true
             } = Antigravity.capabilities()
    end
  end

  describe "build_command/1" do
    test "pins the run worktree via --add-dir (port cwd alone is insufficient — Task 32/198)", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation(cwd))

      add_dir_index = Enum.find_index(argv, &(&1 == "--add-dir"))
      assert add_dir_index, "argv must carry --add-dir"
      assert Enum.at(argv, add_dir_index + 1) == cwd
      p_index = Enum.find_index(argv, &(&1 == "-p"))
      assert add_dir_index < p_index, "--add-dir must precede -p"
    end

    test "builds a headless run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation(cwd))

      assert argv == [
               "--add-dir",
               cwd,
               "--dangerously-skip-permissions",
               "-p",
               RulesInjection.prepend_prompt("do the task")
             ]
    end

    test "rejects any model override", %{cwd: cwd} do
      assert {:error, {:unsupported_model, "custom-model"}} =
               Antigravity.build_command(invocation(cwd, model: "custom-model"))
    end

    test "appends --continue for a :resume session", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} = Antigravity.build_command(invocation(cwd, session: :resume))

      assert argv == [
               "--add-dir",
               cwd,
               "--dangerously-skip-permissions",
               "--continue",
               "-p",
               RulesInjection.prepend_prompt("do the task")
             ]
    end

    test "two concurrent invocations carry distinct --add-dir paths (parallel-batch regression for Task 198)",
         %{cwd: cwd} do
      sibling =
        Path.join(Path.dirname(cwd), "harness-antigravity-sibling-#{System.unique_integer()}")

      File.mkdir_p!(sibling)
      on_exit(fn -> File.rm_rf!(sibling) end)

      assert {:ok, {"agy", argv_a, []}} = Antigravity.build_command(invocation(cwd))
      assert {:ok, {"agy", argv_b, []}} = Antigravity.build_command(invocation(sibling))

      assert Enum.at(argv_a, Enum.find_index(argv_a, &(&1 == "--add-dir")) + 1) == cwd
      assert Enum.at(argv_b, Enum.find_index(argv_b, &(&1 == "--add-dir")) + 1) == sibling
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
end
