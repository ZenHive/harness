defmodule Harness.AgentAdapter.RulesInjectionTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection
  alias Harness.AgentRules

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-inject-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, task_id: "22"}, attrs)
  end

  describe "claude_flags/1" do
    test "returns append-system-prompt flags pointing at an ephemeral file", %{cwd: cwd} do
      assert {:ok, flags} = RulesInjection.claude_flags(invocation(cwd))

      assert flags == [
               "--append-system-prompt-file",
               Path.join(cwd, AgentRules.system_prompt_rel_path()),
               "--exclude-dynamic-system-prompt-sections"
             ]

      assert File.exists?(Path.join(cwd, AgentRules.system_prompt_rel_path()))
    end
  end

  describe "install_codex_rules/1" do
    test "writes AGENTS.md into the worktree", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd))
      assert File.exists?(Path.join(cwd, "AGENTS.md"))
    end
  end

  describe "install_cursor_rules/1" do
    test "writes a cursor rules file into the worktree", %{cwd: cwd} do
      assert :ok = RulesInjection.install_cursor_rules(invocation(cwd))
      assert File.exists?(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
    end
  end

  describe "prepend_prompt/1" do
    test "prepends the same canonical rules used for file delivery" do
      prompt = RulesInjection.prepend_prompt("task body")

      assert prompt =~ AgentRules.render()
      assert String.ends_with?(prompt, "task body")
    end
  end

  describe "canonical parity across delivery channels" do
    test "Claude file, Codex AGENTS.md, and Grok preamble share the same rendered rules", %{
      cwd: cwd
    } do
      canonical = AgentRules.render()

      RulesInjection.claude_flags(invocation(cwd))
      claude_body = File.read!(Path.join(cwd, AgentRules.system_prompt_rel_path()))

      RulesInjection.install_codex_rules(invocation(cwd))
      codex_body = File.read!(Path.join(cwd, "AGENTS.md"))

      grok_prompt = RulesInjection.prepend_prompt("task")

      assert claude_body == canonical
      assert codex_body =~ canonical
      assert grok_prompt =~ canonical
    end
  end
end
