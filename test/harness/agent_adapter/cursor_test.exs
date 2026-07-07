defmodule Harness.AgentAdapter.CursorTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Invocation

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-cursor-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, log_tag: "13"}, attrs)
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
    test "builds a headless stream-json run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation(cwd))

      assert argv == [
               "-p",
               "--output-format",
               "stream-json",
               "--force",
               "--trust",
               "do the task"
             ]

      assert File.exists?(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
    end

    test "maps :autonomous to --force --trust", %{cwd: cwd} do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation(cwd))
      assert "--force" in argv
      assert "--trust" in argv
    end

    test "passes the model through as --model", %{cwd: cwd} do
      assert {:ok, {"cursor-agent", argv, []}} =
               Cursor.build_command(invocation(cwd, model: "sonnet-4"))

      assert Enum.at(argv, -3) == "--model"
      assert Enum.at(argv, -2) == "sonnet-4"
      assert List.last(argv) == "do the task"
    end

    test "appends --continue for a :resume session", %{cwd: cwd} do
      assert {:ok, {"cursor-agent", argv, []}} =
               Cursor.build_command(invocation(cwd, session: :resume))

      assert Enum.at(argv, -2) == "--continue"
      assert List.last(argv) == "do the task"
    end

    test "omits the resume flag for a fresh run", %{cwd: cwd} do
      assert {:ok, {"cursor-agent", argv, []}} = Cursor.build_command(invocation(cwd))
      refute "--continue" in argv
    end

    test "orders model then resume, with the prompt last", %{cwd: cwd} do
      assert {:ok, {"cursor-agent", argv, []}} =
               Cursor.build_command(invocation(cwd, model: "sonnet-4", session: :resume))

      assert Enum.slice(argv, -4..-1//1) == ["--model", "sonnet-4", "--continue", "do the task"]
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Cursor.build_command(invocation(cwd, permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Cursor.build_command(invocation(cwd, session: "abc-123"))
    end
  end
end
