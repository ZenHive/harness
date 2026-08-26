defmodule Harness.AgentRuleDelivery do
  @moduledoc """
  Prepares rule delivery without changing repository-owned instruction files.

  Codex and Pi receive harness rules in the prompt. Other adapters retain the
  native delivery channel declared by the adapter package.
  """

  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentAdapter.RuleDelivery
  alias Harness.AgentAdapter.RulesInjection

  @prompt_adapters [Codex, Pi]

  @doc "Pre-attaches prompt-delivered rules for adapters that discover tracked `AGENTS.md` files."
  @spec prepare(module(), Invocation.t()) :: Invocation.t()
  def prepare(adapter, %Invocation{rules: nil} = invocation) when adapter in @prompt_adapters do
    prompt = RulesInjection.prepend_prompt(invocation.prompt, invocation.rule_content)
    %{invocation | rules: %RuleDelivery{prompt: prompt}}
  end

  def prepare(_adapter, %Invocation{} = invocation), do: invocation
end
