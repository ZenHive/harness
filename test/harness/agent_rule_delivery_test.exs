defmodule Harness.AgentRuleDeliveryTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentAdapter.Testing.FakeAdapter
  alias Harness.AgentDriver
  alias Harness.AgentRuleDelivery
  alias Harness.GitFixture

  @rules "never change tracked project instructions"
  @project_rules "project rules\n"

  describe "prepare/2 for the Codex/Pi channel" do
    test "keeps tracked AGENTS.md fresh through attach_rules and build_command" do
      Enum.each([Codex, Pi], fn adapter ->
        cwd = tracked_agents_repo()
        invocation = invocation(cwd, "audit")
        prepared = AgentRuleDelivery.prepare(adapter, invocation)

        assert {:ok, {_executable, argv, _env}} = adapter.build_command(prepared)
        assert prepared.rules.prompt =~ @rules
        assert prepared.rules.prompt =~ invocation.prompt
        assert List.last(argv) == prepared.rules.prompt
        assert_agents_fresh(cwd)
      end)
    end

    test "native attach_rules still dirties AGENTS.md without prepare" do
      cwd = tracked_agents_repo()
      invocation = invocation(cwd, "audit")

      assert {:ok, _attached} = AgentAdapter.attach_rules(Codex, invocation)
      refute File.read!(Path.join(cwd, "AGENTS.md")) == File.read!(Path.join(cwd, "CLAUDE.md"))
      assert GitFixture.git!(cwd, ["diff", "HEAD", "--", "AGENTS.md"]) =~ "harness-injected"
    end
  end

  test "leaves Claude and Grok on their native channels" do
    cwd = tracked_agents_repo()
    invocation = invocation(cwd, "run")

    assert AgentRuleDelivery.prepare(Claude, invocation).rules == nil
    assert AgentRuleDelivery.prepare(Grok, invocation).rules == nil
  end

  test "prepare is a no-op when rules are already attached" do
    cwd = tracked_agents_repo()
    prepared = AgentRuleDelivery.prepare(Codex, invocation(cwd, "audit"))

    assert AgentRuleDelivery.prepare(Codex, prepared) == prepared
  end

  test "AgentDriver.run still drives a non-codex adapter" do
    cwd = GitFixture.init_repo()

    invocation = %Invocation{
      prompt: "echo",
      cwd: cwd,
      log_tag: "driver",
      adapter_opts: [command: :echo]
    }

    assert {:ok, %Outcome{kind: :exited}} = AgentDriver.run(FakeAdapter, invocation)
  end

  @spec tracked_agents_repo() :: String.t()
  defp tracked_agents_repo do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, "CLAUDE.md"), @project_rules)
    File.write!(Path.join(repo, "AGENTS.md"), @project_rules)
    GitFixture.git!(repo, ["add", "CLAUDE.md", "AGENTS.md"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "track agents"])
    repo
  end

  @spec invocation(String.t(), String.t()) :: Invocation.t()
  defp invocation(cwd, log_tag) do
    %Invocation{prompt: "run the project check", cwd: cwd, log_tag: log_tag, rule_content: @rules}
  end

  @spec assert_agents_fresh(String.t()) :: true
  defp assert_agents_fresh(cwd) do
    assert File.read!(Path.join(cwd, "AGENTS.md")) == File.read!(Path.join(cwd, "CLAUDE.md"))
    assert GitFixture.git!(cwd, ["diff", "HEAD", "--", "AGENTS.md"]) == ""
  end
end
