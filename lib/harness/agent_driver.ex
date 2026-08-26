defmodule Harness.AgentDriver do
  @moduledoc "Runs agent adapters after applying harness-owned rule-delivery policy."

  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentRuleDelivery

  @doc "Runs an adapter with its invocation rules safely attached."
  @spec run(module(), Invocation.t(), keyword()) :: {:ok, Outcome.t()} | {:error, term()}
  def run(adapter, %Invocation{} = invocation, opts \\ []) do
    Driver.run(adapter, AgentRuleDelivery.prepare(adapter, invocation), opts)
  end
end
