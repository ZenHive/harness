defmodule Harness.AgentRuleDelivery do
  @moduledoc """
  Prepares rule delivery without changing repository-owned instruction files.

  Adapters on `:codex_ephemeral_file` (Codex, Pi) would otherwise merge harness
  rules into a tracked `AGENTS.md`. Those runs receive the rules in the prompt
  instead. Other adapters keep the native channel declared by the adapter.
  """

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RuleDelivery
  alias Harness.AgentAdapter.RulesInjection

  @doc "Pre-attaches prompt-delivered rules for the Codex/Pi AGENTS.md channel."
  @spec prepare(module(), Invocation.t()) :: Invocation.t()
  def prepare(adapter, %Invocation{rules: nil} = invocation) do
    reroute_codex_channel(adapter.rule_channel(), invocation)
  end

  def prepare(_adapter, %Invocation{} = invocation), do: invocation

  @spec reroute_codex_channel(atom(), Invocation.t()) :: Invocation.t()
  defp reroute_codex_channel(:codex_ephemeral_file, invocation) do
    prompt = RulesInjection.prepend_prompt(invocation.prompt, invocation.rule_content)
    %{invocation | rules: %RuleDelivery{prompt: prompt}}
  end

  defp reroute_codex_channel(_channel, invocation), do: invocation
end
