defmodule Harness.AgentAdapter.RulesInjectionTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection

  @rule_content "caller supplied rule fixture"
  @other_rule_content "language-filtered caller fixture"
  @system_prompt_rel ".harness/agent-rules.md"

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-inject-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, log_tag: "22", rule_content: @rule_content}, attrs)
  end

  describe "claude_flags/1" do
    test "returns append-system-prompt flags pointing at an ephemeral file", %{cwd: cwd} do
      assert {:ok, flags} = RulesInjection.claude_flags(invocation(cwd))

      assert flags == [
               "--append-system-prompt-file",
               Path.join(cwd, @system_prompt_rel),
               "--exclude-dynamic-system-prompt-sections"
             ]

      assert File.read!(Path.join(cwd, @system_prompt_rel)) == @rule_content
    end

    test "writes the caller-supplied content without rendering it", %{cwd: cwd} do
      assert {:ok, _flags} = RulesInjection.claude_flags(invocation(cwd, rule_content: @other_rule_content))

      assert File.read!(Path.join(cwd, @system_prompt_rel)) == @other_rule_content
    end

    test "returns rule injection errors when the system prompt path cannot be written", %{cwd: cwd} do
      File.write!(Path.join(cwd, ".harness"), "not a directory")

      assert {:error, {:rule_injection_failed, reason}} = RulesInjection.claude_flags(invocation(cwd))
      assert is_atom(reason)
    end
  end

  describe "install_codex_rules/1" do
    test "writes AGENTS.md into the worktree", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd))

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      assert body =~ @rule_content
    end

    test "writes the caller-supplied content without rendering it", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd, rule_content: @other_rule_content))

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      assert body =~ @other_rule_content
      refute body =~ @rule_content
    end

    test "preserves an existing AGENTS.md after the injected block", %{cwd: cwd} do
      File.write!(Path.join(cwd, "AGENTS.md"), "project instructions")
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd))

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      assert body =~ @rule_content
      assert String.ends_with?(body, "project instructions")
    end

    test "returns rule injection errors when AGENTS.md cannot be read", %{cwd: cwd} do
      File.mkdir_p!(Path.join(cwd, "AGENTS.md"))

      assert {:error, {:rule_injection_failed, reason}} = RulesInjection.install_codex_rules(invocation(cwd))
      assert is_atom(reason)
    end
  end

  describe "install_cursor_rules/1" do
    test "writes a cursor rules file into the worktree", %{cwd: cwd} do
      assert :ok = RulesInjection.install_cursor_rules(invocation(cwd))

      body = File.read!(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
      assert body =~ @rule_content
    end

    test "writes the caller-supplied content without rendering it", %{cwd: cwd} do
      assert :ok = RulesInjection.install_cursor_rules(invocation(cwd, rule_content: @other_rule_content))

      body = File.read!(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
      assert body =~ @other_rule_content
      refute body =~ @rule_content
    end

    test "returns rule injection errors when cursor rules cannot be written", %{cwd: cwd} do
      File.write!(Path.join(cwd, ".cursor"), "not a directory")

      assert {:error, {:rule_injection_failed, reason}} = RulesInjection.install_cursor_rules(invocation(cwd))
      assert is_atom(reason)
    end
  end

  describe "prepend_prompt/2" do
    test "prepends caller-supplied rules to the task body" do
      prompt = RulesInjection.prepend_prompt("task body", @rule_content)

      assert prompt =~ @rule_content
      assert String.ends_with?(prompt, "task body")
    end

    test "does not render or filter the supplied content" do
      prompt = RulesInjection.prepend_prompt("task body", @other_rule_content)

      assert prompt =~ @other_rule_content
      refute prompt =~ @rule_content
      assert String.ends_with?(prompt, "task body")
    end
  end

  describe "content parity across delivery channels" do
    test "Claude file, Codex AGENTS.md, and prompt preamble share the same caller content", %{
      cwd: cwd
    } do
      RulesInjection.claude_flags(invocation(cwd))
      claude_body = File.read!(Path.join(cwd, @system_prompt_rel))

      RulesInjection.install_codex_rules(invocation(cwd))
      codex_body = File.read!(Path.join(cwd, "AGENTS.md"))

      grok_prompt = RulesInjection.prepend_prompt("task", @rule_content)

      assert claude_body == @rule_content
      assert codex_body =~ @rule_content
      assert grok_prompt =~ @rule_content
    end
  end

  describe "cleanup_injected_rules/1" do
    test "removes the Claude system-prompt and Cursor rules files", %{cwd: cwd} do
      assert {:ok, _flags} = RulesInjection.claude_flags(invocation(cwd))
      assert :ok = RulesInjection.install_cursor_rules(invocation(cwd))

      assert :ok = RulesInjection.cleanup_injected_rules(cwd)

      refute File.exists?(Path.join(cwd, @system_prompt_rel))
      refute File.exists?(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
    end

    test "strips the injected AGENTS.md block and preserves repo content", %{cwd: cwd} do
      agents = Path.join(cwd, "AGENTS.md")
      File.write!(agents, "target repo instructions")

      assert :ok = RulesInjection.install_codex_rules(invocation(cwd))
      assert :ok = RulesInjection.cleanup_injected_rules(cwd)

      assert File.read!(agents) == "target repo instructions"
    end

    test "removes an AGENTS.md that is entirely the injected block", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd))

      assert :ok = RulesInjection.cleanup_injected_rules(cwd)

      refute File.exists?(Path.join(cwd, "AGENTS.md"))
    end

    test "removes a marker-prefixed AGENTS.md with no separator (legacy whole-block file)", %{cwd: cwd} do
      agents = Path.join(cwd, "AGENTS.md")

      File.write!(
        agents,
        "<!-- harness-injected: canonical agent rules — ephemeral, do not commit -->\nlegacy block body"
      )

      assert :ok = RulesInjection.cleanup_injected_rules(cwd)

      refute File.exists?(agents)
    end

    test "leaves a repo-owned AGENTS.md without the marker untouched", %{cwd: cwd} do
      agents = Path.join(cwd, "AGENTS.md")
      File.write!(agents, "repo instructions, never injected")

      assert :ok = RulesInjection.cleanup_injected_rules(cwd)

      assert File.read!(agents) == "repo instructions, never injected"
    end

    test "is a no-op when nothing was injected", %{cwd: cwd} do
      assert :ok = RulesInjection.cleanup_injected_rules(cwd)
    end
  end
end
