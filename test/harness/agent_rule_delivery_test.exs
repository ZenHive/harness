defmodule Harness.AgentRuleDeliveryTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentRuleDelivery

  @rules "never change tracked project instructions"

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-safe-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "CLAUDE.md"), "project rules\n")
    File.write!(Path.join(cwd, "AGENTS.md"), "project rules\n")
    System.cmd("git", ["init", "-q", cwd])
    System.cmd("git", ["-C", cwd, "add", "CLAUDE.md", "AGENTS.md"])
    on_exit(fn -> File.rm_rf!(cwd) end)

    invocation = %Invocation{prompt: "run the project check", cwd: cwd, log_tag: "audit", rule_content: @rules}
    {:ok, cwd: cwd, invocation: invocation}
  end

  for adapter <- [Codex, Pi] do
    test "#{inspect(adapter)} receives rules while the tracked freshness check stays green", %{
      cwd: cwd,
      invocation: invocation
    } do
      prepared = AgentRuleDelivery.prepare(unquote(adapter), invocation)

      assert prepared.rules.prompt =~ @rules
      assert prepared.rules.prompt =~ invocation.prompt
      assert File.read!(Path.join(cwd, "AGENTS.md")) == File.read!(Path.join(cwd, "CLAUDE.md"))
      assert {"", 0} = System.cmd("git", ["-C", cwd, "diff", "--", "AGENTS.md"])
    end
  end
end
