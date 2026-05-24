defmodule Harness.NoncompliantAdapter do
  @moduledoc false

  # Deliberately omits `Harness.AgentAdapter.attach_rules/2` in build_command/1
  # to prove ConformanceCase catches adapters that skip rule injection.

  use Harness.AgentAdapter

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @impl Harness.AgentAdapter
  def capabilities, do: %Capabilities{}

  @impl Harness.AgentAdapter
  def rule_channel, do: :prompt_preamble

  @impl Harness.AgentAdapter
  def build_command(%Invocation{} = invocation) do
    {:ok, {"noncompliant", ["-p", invocation.prompt], Map.to_list(invocation.env)}}
  end
end
