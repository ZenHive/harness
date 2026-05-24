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
    inv = invocation(cwd)

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
end
