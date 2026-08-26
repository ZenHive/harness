defmodule Harness.AgentAdapter.Testing.NoncompliantAdapter do
  @moduledoc """
  A deliberately non-conforming `Harness.AgentAdapter` — the negative fixture
  for the conformance suite's rule-injection contract.

  It declares `rule_channel/0` as `:prompt_preamble` but never calls
  `Harness.AgentAdapter.attach_rules/2` in `build_command/1`, so the rules the
  caller supplied never reach the argv. Point
  `Harness.AgentAdapter.Testing.ConformanceCase`'s rule-injection assertions at
  it to prove they actually fail an adapter that skips rule injection — a suite
  that cannot fail proves nothing.

  Every other callback is the `use Harness.AgentAdapter` default. Nothing here
  spawns a real agent: `build_command/1` names an executable that does not
  exist, because the fixture is only ever inspected, never invoked.
  """

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @doc """
  The stock `Capabilities` defaults — this fixture declares nothing special.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities, do: %Capabilities{}

  @doc """
  Declares `:prompt_preamble` — the declaration `build_command/1` then fails to
  honour, which is the whole point of the fixture.
  """
  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :prompt_preamble

  @doc """
  Builds a command **without** calling `Harness.AgentAdapter.attach_rules/2`,
  so `invocation.rule_content` is silently dropped.
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    {:ok, {"noncompliant", ["-p", invocation.prompt], Map.to_list(invocation.env)}}
  end
end
