defmodule Harness.Insights.Selection do
  @moduledoc "Observer choices from operator enablement, standing pins and selected catalogs."
  alias Harness.Agent.Settings
  alias Harness.AgentRegistry
  alias Harness.Config
  alias Harness.ModelAvailability

  @doc "Lists supported enabled observers and their available selected models."
  @spec choices() :: [map()]
  def choices do
    for agent <- [:codex, :claude], Settings.enabled?(agent) do
      %{agent: Atom.to_string(agent), models: ModelAvailability.list_available_ids(agent)}
    end
  end

  @doc "Defaults to the configured Codex standing model without selecting another provider."
  @spec default() :: map()
  def default, do: %{"agent" => "codex", "model" => Config.agent_model(:codex)}

  @doc "Checks the exact selection, including runtime availability, without falling back."
  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(%{"agent" => name, "model" => model}) when name in ["codex", "claude"] do
    agent = if name == "codex", do: :codex, else: :claude
    adapter = Map.get(AgentRegistry.agents(), agent)

    cond do
      not Settings.enabled?(agent) ->
        {:error, :agent_disabled}

      model in [nil, ""] ->
        {:error, :model_required}

      model not in ModelAvailability.list_available_ids(agent) ->
        {:error, :model_unavailable}

      is_nil(adapter) or not AgentRegistry.installed?(adapter) or not AgentRegistry.available?(adapter) ->
        {:error, :agent_unavailable}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :unsupported_observer}
end
