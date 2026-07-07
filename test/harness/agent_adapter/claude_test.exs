defmodule Harness.AgentAdapter.ClaudeTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Invocation

  @rule_content "claude rules fixture"
  @system_prompt_rel ".harness/agent-rules.md"

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-claude-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, log_tag: "7", rule_content: @rule_content}, attrs)
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
    test "builds a headless stream-json run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation(cwd))

      assert argv == [
               "-p",
               "--output-format",
               "stream-json",
               "--verbose",
               "--permission-mode",
               "bypassPermissions",
               "--append-system-prompt-file",
               Path.join(cwd, @system_prompt_rel),
               "--exclude-dynamic-system-prompt-sections",
               "do the task"
             ]

      assert File.read!(Path.join(cwd, @system_prompt_rel)) == @rule_content
    end

    test "passes the model through as --model", %{cwd: cwd} do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation(cwd, model: "opus"))

      assert Enum.at(argv, -3) == "--model"
      assert Enum.at(argv, -2) == "opus"
      assert List.last(argv) == "do the task"
    end

    test "appends --continue for a :resume session", %{cwd: cwd} do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation(cwd, session: :resume))
      assert Enum.at(argv, -2) == "--continue"
      assert List.last(argv) == "do the task"
    end

    test "omits the resume flag for a fresh run", %{cwd: cwd} do
      assert {:ok, {"claude", argv, []}} = Claude.build_command(invocation(cwd))
      refute "--continue" in argv
    end

    test "orders model then resume, with the prompt last", %{cwd: cwd} do
      assert {:ok, {"claude", argv, []}} =
               Claude.build_command(invocation(cwd, model: "opus", session: :resume))

      assert Enum.slice(argv, -4..-1//1) == ["--model", "opus", "--continue", "do the task"]
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Claude.build_command(invocation(cwd, permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Claude.build_command(invocation(cwd, session: "abc-123"))
    end
  end
end
