defmodule Harness.AgentDriver do
  @moduledoc """
  Single harness-owned entry point for running an agent adapter.

  Applies rule-delivery policy, then drives the adapter through
  `Harness.AgentAdapter.Driver`. Codex/Pi runs receive harness rules in the
  prompt so a tracked `AGENTS.md` is never modified.
  """

  use Descripex, namespace: "/agent_driver"

  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentRuleDelivery

  api(:run, "Spawn an adapter after applying harness rule-delivery policy and drive it to completion.",
    params: [
      adapter: [
        kind: :value,
        description:
          "Adapter module implementing Harness.AgentAdapter (e.g. Harness.AgentAdapter.Claude). The caller supplies the module atom."
      ],
      invocation: [
        kind: :value,
        description:
          "Harness.AgentAdapter.Invocation struct. Caller-constructed: cwd, prompt, log_tag, env scrub map, adapter_opts, model, rule_content."
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword list. :total_timeout / :idle_timeout / :progress_timeout (ms overrides). :on_spawn (1-arity hook called with the Run handle the moment the agent spawns). :on_output (1-arity hook called with each iodata chunk). Hook exceptions are swallowed."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Harness.AgentAdapter.Outcome{}} for any spawned run (including timeouts / mid-run port errors). {:error, reason} only when nothing spawned (build_command/1 failed, executable missing)."
    }
  )

  @spec run(module(), Invocation.t(), keyword()) :: {:ok, Outcome.t()} | {:error, term()}
  def run(adapter, %Invocation{} = invocation, opts \\ []) do
    Driver.run(adapter, AgentRuleDelivery.prepare(adapter, invocation), opts)
  end
end
