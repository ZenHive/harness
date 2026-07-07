defmodule Harness.AgentAdapter.GrokTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection

  @rule_content "grok rules fixture"

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-grok-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, log_tag: "15", rule_content: @rule_content}, attrs)
  end

  defp expected_prompt, do: RulesInjection.prepend_prompt("do the task", @rule_content)

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous]
             } = Grok.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless streaming-json run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"grok", argv, []}} = Grok.build_command(invocation(cwd))

      assert [
               "--output-format",
               "streaming-json",
               "--permission-mode",
               "bypassPermissions",
               "-p",
               prompt
             ] = argv

      assert prompt == expected_prompt()
    end

    test "passes the model through as --model", %{cwd: cwd} do
      assert {:ok, {"grok", argv, []}} =
               Grok.build_command(invocation(cwd, model: "grok-code-fast-1"))

      model_idx = Enum.find_index(argv, &(&1 == "--model"))
      assert model_idx
      assert Enum.at(argv, model_idx + 1) == "grok-code-fast-1"
      assert List.last(argv) == expected_prompt()
    end

    test "appends --continue for a :resume session", %{cwd: cwd} do
      assert {:ok, {"grok", argv, []}} = Grok.build_command(invocation(cwd, session: :resume))
      assert Enum.at(argv, -3) == "--continue"
      assert List.last(argv) == expected_prompt()
    end

    test "omits the resume flag for a fresh run", %{cwd: cwd} do
      assert {:ok, {"grok", argv, []}} = Grok.build_command(invocation(cwd))
      refute "--continue" in argv
    end

    test "orders model then resume, with the prompt flag last", %{cwd: cwd} do
      assert {:ok, {"grok", argv, []}} =
               Grok.build_command(invocation(cwd, model: "grok-code-fast-1", session: :resume))

      assert Enum.slice(argv, -5..-1//1) == [
               "--model",
               "grok-code-fast-1",
               "--continue",
               "-p",
               expected_prompt()
             ]
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Grok.build_command(invocation(cwd, permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Grok.build_command(invocation(cwd, session: "abc-123"))
    end
  end
end
