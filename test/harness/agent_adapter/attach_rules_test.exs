defmodule Harness.AgentAdapter.ConformanceCaseRulesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection
  alias Harness.NoncompliantAdapter

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-noncompliant-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  test "ConformanceCase rule-injection test fails when an adapter omits attach_rules/2", %{
    cwd: cwd
  } do
    inv = %Invocation{
      prompt: "conformance rules probe",
      cwd: cwd,
      task_id: "conformance"
    }

    assert {:ok, {_executable, argv, _env}} = NoncompliantAdapter.build_command(inv)
    refute RulesInjection.prepend_prompt("conformance rules probe") in argv

    assert_raise ExUnit.AssertionError, fn ->
      run_conformance_rule_injection_test(NoncompliantAdapter, inv)
    end
  end

  defp run_conformance_rule_injection_test(adapter, inv) do
    assert {:ok, {_executable, argv, _env}} = adapter.build_command(inv)

    :prompt_preamble = adapter.rule_channel()
    expected = RulesInjection.prepend_prompt(inv.prompt)
    assert expected in argv
  end
end

defmodule Harness.AgentAdapter.AttachRulesTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection
  alias Harness.AgentRules

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-attach-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "task", cwd: cwd, task_id: "39"}, attrs)
  end

  test "attach_rules/2 is idempotent once rules are present", %{cwd: cwd} do
    inv = invocation(cwd)

    assert {:ok, attached} = AgentAdapter.attach_rules(Claude, inv)
    assert attached.rules.argv_flags != []

    assert {:ok, ^attached} = AgentAdapter.attach_rules(Claude, attached)
  end

  test "invoke/2 attaches rules before build_command/1", %{cwd: cwd} do
    inv = invocation(cwd, model: "claude-opus-4-8-thinking-high")

    assert {:ok, run} = AgentAdapter.invoke(Claude, inv)
    assert run.adapter == Claude
  end

  test "task_prompt/1 returns the preamble-augmented prompt for :prompt_preamble", %{cwd: cwd} do
    inv = invocation(cwd)

    assert {:ok, inv} = AgentAdapter.attach_rules(Grok, inv)
    assert AgentAdapter.task_prompt(inv) == RulesInjection.prepend_prompt("task")
  end

  test "attach_rules/2 for :system_prompt_file writes the ephemeral file", %{cwd: cwd} do
    inv = invocation(cwd)

    assert {:ok, inv} = AgentAdapter.attach_rules(Claude, inv)
    assert File.exists?(Path.join(cwd, AgentRules.system_prompt_rel_path()))
    assert inv.rules.argv_flags != []
  end

  test "composed_input/3 captures prompt preamble delivery", %{cwd: cwd} do
    inv = invocation(cwd)

    assert {:ok, inv} = AgentAdapter.attach_rules(Grok, inv)
    assert {:ok, {_exe, argv, _env} = command} = Grok.build_command(inv)

    assert %{
             rule_channel: :prompt_preamble,
             prompt: prompt,
             rule_files: [],
             argv: ^argv
           } = AgentAdapter.composed_input(Grok, inv, command)

    assert prompt == RulesInjection.prepend_prompt("task")
    assert prompt in argv
  end

  test "composed_input/3 captures file-backed rule delivery", %{cwd: cwd} do
    inv = invocation(cwd)

    assert {:ok, inv} = AgentAdapter.attach_rules(Claude, inv)
    assert {:ok, {_exe, argv, _env} = command} = Claude.build_command(inv)

    assert %{
             rule_channel: :system_prompt_file,
             prompt: "task",
             rule_files: [%{path: path, content: content}],
             argv: ^argv
           } = AgentAdapter.composed_input(Claude, inv, command)

    assert path == Path.join(cwd, AgentRules.system_prompt_rel_path())
    assert content == AgentRules.render()
  end

  test "composed_input/3 captures native ephemeral rule files", %{cwd: cwd} do
    codex_inv = invocation(cwd)
    cursor_inv = invocation(cwd, task_id: "40")

    assert {:ok, codex_inv} = AgentAdapter.attach_rules(Codex, codex_inv)
    assert {:ok, codex_command} = Codex.build_command(codex_inv)

    assert %{rule_channel: :codex_ephemeral_file, rule_files: [codex_rules]} =
             AgentAdapter.composed_input(Codex, codex_inv, codex_command)

    assert codex_rules.path == Path.join(cwd, "AGENTS.md")
    assert codex_rules.content =~ AgentRules.render()

    assert {:ok, cursor_inv} = AgentAdapter.attach_rules(Cursor, cursor_inv)
    assert {:ok, cursor_command} = Cursor.build_command(cursor_inv)

    assert %{rule_channel: :cursor_ephemeral_file, rule_files: [cursor_rules]} =
             AgentAdapter.composed_input(Cursor, cursor_inv, cursor_command)

    assert cursor_rules.path == Path.join(cwd, ".cursor/rules/harness-operational.mdc")
    assert cursor_rules.content =~ AgentRules.render()
  end
end
