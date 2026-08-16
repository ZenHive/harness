defmodule Harness.AgentAdapter.AntigravityTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection

  @rule_content "antigravity rules fixture"

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-antigravity-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, log_tag: "26", rule_content: @rule_content}, attrs)
  end

  defp expected_prompt, do: RulesInjection.prepend_prompt("do the task", @rule_content)

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode, worktree isolation, and model families" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous],
               worktree_isolation: true,
               model_families: [:google, :anthropic, :openai]
             } = Antigravity.capabilities()
    end
  end

  describe "display_label_to_id/1" do
    test "maps an enumerated display label to its dash-form id" do
      assert Antigravity.display_label_to_id("Claude Sonnet 4.6 (Thinking)") == "claude-sonnet-4-5"
    end

    test "tolerates a reasoning suffix the catalog did not enumerate (live agy emits GPT-OSS 120B (Medium))" do
      assert Antigravity.display_label_to_id("GPT-OSS 120B (Medium)") == "gpt-oss-120b"
    end

    test "returns nil for an unknown label" do
      assert Antigravity.display_label_to_id("Totally Made Up 9000") == nil
    end
  end

  describe "build_command/1" do
    test "pins the run worktree via --add-dir (port cwd alone is insufficient — Task 32/198)", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} =
               Antigravity.build_command(invocation(cwd, model: "gemini-3.5-flash"))

      add_dir_index = Enum.find_index(argv, &(&1 == "--add-dir"))
      assert add_dir_index, "argv must carry --add-dir"
      assert Enum.at(argv, add_dir_index + 1) == cwd
      p_index = Enum.find_index(argv, &(&1 == "-p"))
      assert add_dir_index < p_index, "--add-dir must precede -p"
    end

    test "builds a headless run for the autonomous baseline with --model", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} =
               Antigravity.build_command(invocation(cwd, model: "gemini-3.5-flash"))

      assert argv == [
               "--add-dir",
               cwd,
               "--dangerously-skip-permissions",
               "--model",
               "gemini-3.5-flash",
               "-p",
               expected_prompt()
             ]
    end

    test "passes through a model outside the verified catalog but within a declared family (overlay regression — a new Claude/Gemini/GPT generation must not be hard-blocked)",
         %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} =
               Antigravity.build_command(invocation(cwd, model: "claude-opus-5"))

      assert "--model" in argv
      assert "claude-opus-5" in argv
    end

    test "appends --continue for a :resume session", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} =
               Antigravity.build_command(invocation(cwd, model: "gemini-3.5-flash", session: :resume))

      assert argv == [
               "--add-dir",
               cwd,
               "--dangerously-skip-permissions",
               "--model",
               "gemini-3.5-flash",
               "--continue",
               "-p",
               expected_prompt()
             ]
    end

    test "two concurrent invocations carry distinct --add-dir paths (parallel-batch regression for Task 198)",
         %{cwd: cwd} do
      sibling =
        Path.join(Path.dirname(cwd), "harness-antigravity-sibling-#{System.unique_integer()}")

      File.mkdir_p!(sibling)
      on_exit(fn -> File.rm_rf!(sibling) end)

      assert {:ok, {"agy", argv_a, []}} =
               Antigravity.build_command(invocation(cwd, model: "gemini-3.5-flash"))

      assert {:ok, {"agy", argv_b, []}} =
               Antigravity.build_command(invocation(sibling, model: "gemini-3.5-flash"))

      assert Enum.at(argv_a, Enum.find_index(argv_a, &(&1 == "--add-dir")) + 1) == cwd
      assert Enum.at(argv_b, Enum.find_index(argv_b, &(&1 == "--add-dir")) + 1) == sibling
    end

    test "omits the resume flag for a fresh run", %{cwd: cwd} do
      assert {:ok, {"agy", argv, []}} =
               Antigravity.build_command(invocation(cwd, model: "gemini-3.5-flash"))

      refute "--continue" in argv
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Antigravity.build_command(invocation(cwd, model: "gemini-3.5-flash", permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Antigravity.build_command(invocation(cwd, model: "gemini-3.5-flash", session: "abc-123"))
    end
  end

  describe "invoke/2 — model-required guard" do
    test "rejects a model-less dispatch before spawn", %{cwd: cwd} do
      assert {:error, {:model_required, Antigravity}} =
               AgentAdapter.invoke(Antigravity, invocation(cwd))
    end

    test "rejects a model outside every declared family before spawn (agy --model is non-validating)",
         %{cwd: cwd} do
      assert {:error, {:invalid_model_for_adapter, Antigravity, "__nope__"}} =
               AgentAdapter.invoke(Antigravity, invocation(cwd, model: "__nope__"))
    end
  end
end
