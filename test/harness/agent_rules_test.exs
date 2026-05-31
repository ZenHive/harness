defmodule Harness.AgentRulesTest do
  use ExUnit.Case, async: true

  alias Harness.AgentRules

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-rules-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  describe "render/1" do
    test "includes operational and methodology sections by default" do
      rendered = AgentRules.render()

      assert rendered =~ "Harness operation"
      assert rendered =~ "Development methodology"
      assert rendered =~ "verification stack is the grader"
    end

    test "excludes verification gate thresholds from the injected set" do
      rendered = AgentRules.render()

      refute rendered =~ "Verification gates (harness-enforced"
      refute rendered =~ "Coverage thresholds"
      refute rendered =~ "mix credo --strict"
    end

    test "can include verification gates when explicitly requested" do
      rendered = AgentRules.render(exclude: [])

      assert rendered =~ "Verification gates (harness-enforced"
      assert rendered =~ "Coverage thresholds"
    end

    test "supports rendering an explicit section subset" do
      rendered = AgentRules.render(only: [:operational])

      assert rendered =~ "Harness operation"
      refute rendered =~ "Development methodology"
      refute rendered =~ "Elixir conventions"
    end
  end

  describe "write_system_prompt_file!/2" do
    test "writes rendered rules under .harness/ in the worktree", %{cwd: cwd} do
      path = AgentRules.write_system_prompt_file!(cwd)
      rel = AgentRules.system_prompt_rel_path()

      assert path == Path.join(cwd, rel)
      assert File.exists?(path)

      body = File.read!(path)
      assert body =~ "Harness operation"
      refute body =~ "Coverage thresholds"
    end
  end

  describe "install_codex_rules!/2" do
    test "writes an ephemeral AGENTS.md with harness rules", %{cwd: cwd} do
      :ok = AgentRules.install_codex_rules!(cwd)

      body = File.read!(Path.join(cwd, "AGENTS.md"))
      assert body =~ "harness-injected: canonical agent rules"
      assert body =~ "Harness operation"
      refute body =~ "Coverage thresholds"
    end

    test "prepends harness rules before an existing AGENTS.md", %{cwd: cwd} do
      agents = Path.join(cwd, "AGENTS.md")
      File.write!(agents, "target repo instructions")

      :ok = AgentRules.install_codex_rules!(cwd)

      body = File.read!(agents)
      assert body =~ "harness-injected: canonical agent rules"
      assert body =~ "target repo instructions"
      assert String.starts_with?(body, "<!-- harness-injected")
    end

    test "cleans up a filtered ephemeral AGENTS.md", %{cwd: cwd} do
      :ok = AgentRules.install_codex_rules!(cwd, exclude: [:verification_gates, :elixir])

      assert :ok = AgentRules.cleanup_injected_rules(cwd)
      refute File.exists?(Path.join(cwd, "AGENTS.md"))
    end
  end

  describe "install_cursor_rules!/2" do
    test "writes an ephemeral .cursor/rules file", %{cwd: cwd} do
      :ok = AgentRules.install_cursor_rules!(cwd)

      path = Path.join(cwd, ".cursor/rules/harness-operational.mdc")
      assert File.exists?(path)

      body = File.read!(path)
      assert body =~ "alwaysApply: true"
      assert body =~ "Harness operation"
      refute body =~ "Coverage thresholds"
    end
  end

  describe "prompt_preamble/1" do
    test "wraps rendered rules for prompt-prepend delivery" do
      preamble = AgentRules.prompt_preamble()

      assert preamble =~ "# Harness operational rules"
      assert preamble =~ "Harness operation"
      assert String.ends_with?(preamble, "---\n\n")
      refute preamble =~ "Coverage thresholds"
    end
  end

  describe "section_ids/0" do
    test "lists tagged sections from the canonical source" do
      ids = AgentRules.section_ids()

      assert :operational in ids
      assert :methodology in ids
      assert :elixir in ids
      assert :verification_gates in ids
    end
  end
end
