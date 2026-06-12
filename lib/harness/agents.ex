defmodule Harness.Agents do
  @moduledoc """
  Read-only operator surface for agent install, enablement, and reviewer facts.

  Counts mechanical state only: adapter registration, binary installation,
  operator enablement, reviewer eligibility, runtime availability, configured
  model pins, and the reviewer slate. No routing verdict or best-reviewer
  judgment lives here.
  """

  use Descripex, namespace: "/agents"

  alias Harness.Agent.Settings
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentRegistry
  alias Harness.Config
  alias Harness.Run

  @typedoc "JSON-safe per-agent operator state."
  @type agent_state :: %{
          agent: String.t(),
          installed: boolean(),
          available: boolean(),
          enabled: boolean(),
          reviewer_eligible: boolean(),
          dispatchable_as_reviewer: boolean(),
          cost_tier: String.t(),
          capabilities: map(),
          model: String.t() | nil,
          reviewer_model: String.t() | nil,
          unavailable_reason: String.t() | nil
        }

  api(:list, "List harness agent install, enablement, reviewer, capability, and model-pin facts.",
    returns: %{
      type: :list,
      description:
        "[%{agent, installed, available, enabled, reviewer_eligible, dispatchable_as_reviewer, cost_tier, capabilities, model, reviewer_model, unavailable_reason}]"
    }
  )

  @spec list() :: [agent_state()]
  def list do
    unavailable = Map.new(AgentRegistry.list_unavailable())

    AgentRegistry.agents()
    |> ordered_agents()
    |> Enum.map(fn {agent, module} -> agent_state(agent, module, unavailable) end)
  end

  api(:reviewers, "Return the ordered installed reviewer slate, optionally excluding one implementer family.",
    params: [
      implementer: [
        kind: :value,
        default: nil,
        description: "Optional implementer agent name string to exclude from the cross-family reviewer slate.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :list,
      description:
        "[%{agent, installed, available, enabled, reviewer_eligible, dispatchable_as_reviewer, cost_tier, capabilities, model, reviewer_model, unavailable_reason}] ordered by Harness.Run.prioritize_reviewers/2."
    }
  )

  @spec reviewers(String.t() | atom() | nil) :: [agent_state()]
  def reviewers(implementer \\ nil) do
    implementer = normalize_agent(implementer)
    unavailable = Map.new(AgentRegistry.list_unavailable())

    AgentRegistry.agents()
    |> ordered_agents()
    |> reject_implementer(implementer)
    |> Enum.filter(fn {_agent, module} -> Run.reviewer_dispatchable?(module) end)
    |> Run.prioritize_reviewers(%{})
    |> Enum.map(fn {agent, module} -> agent_state(agent, module, unavailable) end)
  end

  @spec agent_state(atom(), module(), map()) :: agent_state()
  defp agent_state(agent, module, unavailable) do
    capabilities = module.capabilities()

    %{
      agent: Atom.to_string(agent),
      installed: AgentRegistry.installed?(module),
      available: AgentRegistry.available?(module),
      enabled: Settings.enabled?(agent),
      reviewer_eligible: Settings.reviewer_eligible?(agent),
      dispatchable_as_reviewer: Run.reviewer_dispatchable?(module),
      cost_tier: Atom.to_string(capabilities.cost_tier),
      capabilities: capabilities_map(capabilities),
      model: Config.agent_model(agent),
      reviewer_model: Config.reviewer_model(agent),
      unavailable_reason: unavailable_reason(Map.get(unavailable, module))
    }
  end

  @spec ordered_agents(%{atom() => module()}) :: [{atom(), module()}]
  defp ordered_agents(agents) do
    Enum.flat_map(Config.dispatch_agents(), fn agent ->
      case Map.fetch(agents, agent) do
        {:ok, module} -> [{agent, module}]
        :error -> []
      end
    end)
  end

  @spec reject_implementer([{atom(), module()}], atom() | nil) :: [{atom(), module()}]
  defp reject_implementer(agents, nil), do: agents
  defp reject_implementer(agents, implementer), do: Enum.reject(agents, fn {agent, _module} -> agent == implementer end)

  @spec normalize_agent(String.t() | atom() | nil) :: atom() | nil
  defp normalize_agent(nil), do: nil
  defp normalize_agent(agent) when is_atom(agent), do: if(agent in Config.dispatch_agents(), do: agent)

  defp normalize_agent(agent) when is_binary(agent) do
    Enum.find(Config.dispatch_agents(), &(Atom.to_string(&1) == agent))
  end

  @spec unavailable_reason(term()) :: String.t() | nil
  defp unavailable_reason(nil), do: nil
  defp unavailable_reason(reason), do: inspect(reason)

  @spec capabilities_map(Capabilities.t()) :: map()
  defp capabilities_map(%Capabilities{} = capabilities) do
    %{
      session_resume: capabilities.session_resume,
      permission_modes: stringify_atoms(capabilities.permission_modes),
      streaming_output: capabilities.streaming_output,
      worktree_isolation: capabilities.worktree_isolation,
      cost_tier: Atom.to_string(capabilities.cost_tier),
      auth_env_scrub: capabilities.auth_env_scrub,
      model_families: model_families(capabilities.model_families)
    }
  end

  @spec model_families(Capabilities.model_families()) :: String.t() | [String.t()]
  defp model_families(:any), do: "any"
  defp model_families(families), do: stringify_atoms(families)

  @spec stringify_atoms([atom()]) :: [String.t()]
  defp stringify_atoms(atoms), do: Enum.map(atoms, &Atom.to_string/1)
end
