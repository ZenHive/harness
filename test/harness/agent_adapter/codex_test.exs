defmodule Harness.AgentAdapter.CodexTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Invocation

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-codex-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, task_id: "7"}, attrs)
  end

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous]
             } = Codex.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless --json run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd))

      assert argv == ["exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "do the task"]
      assert File.exists?(Path.join(cwd, "AGENTS.md"))
    end

    test "passes the model through as --model", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} =
               Codex.build_command(invocation(cwd, model: "gpt-5-codex"))

      assert argv == [
               "exec",
               "--json",
               "--dangerously-bypass-approvals-and-sandbox",
               "--model",
               "gpt-5-codex",
               "do the task"
             ]
    end

    test "swaps in the resume subcommand and appends --last for a :resume session", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd, session: :resume))

      assert argv == [
               "exec",
               "resume",
               "--json",
               "--dangerously-bypass-approvals-and-sandbox",
               "--last",
               "do the task"
             ]
    end

    test "omits the resume subcommand and --last for a fresh run", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd))
      refute "resume" in argv
      refute "--last" in argv
    end

    test "orders model then --last, with the prompt last on a resume", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} =
               Codex.build_command(invocation(cwd, model: "gpt-5-codex", session: :resume))

      assert argv == [
               "exec",
               "resume",
               "--json",
               "--dangerously-bypass-approvals-and-sandbox",
               "--model",
               "gpt-5-codex",
               "--last",
               "do the task"
             ]
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Codex.build_command(invocation(cwd, permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Codex.build_command(invocation(cwd, session: "abc-123"))
    end
  end
end
