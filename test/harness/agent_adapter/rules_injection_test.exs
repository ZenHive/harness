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

  defp elixir_conventions, do: "Every public function gets a `@spec`"
  defp verification_gates, do: "Coverage thresholds"

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

    test "keeps Elixir conventions for Elixir-language targets", %{cwd: cwd} do
      assert {:ok, _flags} = RulesInjection.claude_flags(invocation(cwd, language: :elixir))

      body = File.read!(Path.join(cwd, AgentRules.system_prompt_rel_path()))
      assert body =~ elixir_conventions()
      refute body =~ verification_gates()
    end

    test "excludes Elixir conventions for non-Elixir targets", %{cwd: cwd} do
      assert {:ok, _flags} = RulesInjection.claude_flags(invocation(cwd, language: :typescript))

      body = File.read!(Path.join(cwd, AgentRules.system_prompt_rel_path()))
      refute body =~ elixir_conventions()
      refute body =~ verification_gates()
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
      assert File.exists?(Path.join(cwd, "AGENTS.md"))
    end

    test "defaults unknown language to Elixir conventions", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd))

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      assert body =~ elixir_conventions()
      refute body =~ verification_gates()
    end

    test "keeps Elixir conventions when language is explicit Elixir", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd, language: :elixir))

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      assert body =~ elixir_conventions()
      refute body =~ verification_gates()
    end

    test "excludes Elixir conventions for Rust language", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd, language: :rust))

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      refute body =~ elixir_conventions()
      refute body =~ verification_gates()
    end

    test "excludes Elixir conventions for TypeScript language", %{cwd: cwd} do
      assert :ok = RulesInjection.install_codex_rules(invocation(cwd, language: :typescript))

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      refute body =~ elixir_conventions()
      refute body =~ verification_gates()
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
      assert File.exists?(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
    end

    test "excludes Elixir conventions for Rust language", %{cwd: cwd} do
      assert :ok = RulesInjection.install_cursor_rules(invocation(cwd, language: :rust))

      body = File.read!(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
      refute body =~ elixir_conventions()
      refute body =~ verification_gates()
    end

    test "excludes Elixir conventions for TypeScript language", %{cwd: cwd} do
      assert :ok = RulesInjection.install_cursor_rules(invocation(cwd, language: :typescript))

      body = File.read!(Path.join(cwd, ".cursor/rules/harness-operational.mdc"))
      refute body =~ elixir_conventions()
      refute body =~ verification_gates()
    end

    test "returns rule injection errors when cursor rules cannot be written", %{cwd: cwd} do
      File.write!(Path.join(cwd, ".cursor"), "not a directory")

      assert {:error, {:rule_injection_failed, reason}} = RulesInjection.install_cursor_rules(invocation(cwd))
      assert is_atom(reason)
    end
  end

  describe "prepend_prompt/1" do
    test "prepends the same canonical rules used for file delivery" do
      prompt = RulesInjection.prepend_prompt("task body")

      assert prompt =~ AgentRules.render()
      assert String.ends_with?(prompt, "task body")
    end

    test "excludes Elixir conventions for Rust language", %{cwd: cwd} do
      prompt = RulesInjection.prepend_prompt("task body", invocation(cwd, language: :rust))

      refute prompt =~ elixir_conventions()
      refute prompt =~ verification_gates()
      assert String.ends_with?(prompt, "task body")
    end

    test "excludes Elixir conventions for TypeScript language", %{cwd: cwd} do
      prompt = RulesInjection.prepend_prompt("task body", invocation(cwd, language: :typescript))

      refute prompt =~ elixir_conventions()
      refute prompt =~ verification_gates()
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
