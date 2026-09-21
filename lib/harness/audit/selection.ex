defmodule Harness.Audit.Selection do
  @moduledoc "Persisted operator selection for a separate post-merge audit session."

  alias Harness.Agent.Settings
  alias Harness.AgentRegistry
  alias Harness.Config
  alias Harness.ModelAvailability
  alias Harness.SettingsStore

  @doc "Reads the explicit auditor and model; an empty agent retains automatic selection."
  @spec settings() :: map()
  def settings do
    defaults = %{"agent" => "", "model" => ""}

    case SettingsStore.fetch(:audit_selection) do
      :not_found -> defaults
      {:ok, %{"agent" => _, "model" => _} = saved} -> saved
      other -> Map.put(defaults, "error", inspect(other))
    end
  end

  @doc "Saves one validated selection atomically without changing reviewer trust."
  @spec configure(String.t(), String.t()) :: :ok | {:error, term()}
  def configure("", _model), do: SettingsStore.put(:audit_selection, %{"agent" => "", "model" => ""})

  def configure(name, model) when is_binary(name) and is_binary(model) do
    selection = %{"agent" => name, "model" => String.trim(model)}

    with {:ok, _module} <- resolve(selection) do
      SettingsStore.put(:audit_selection, selection)
    end
  end

  @doc "Resolves explicit settings without falling back to another agent or model."
  @spec resolve(map()) :: :automatic | {:ok, module()} | {:error, term()}
  def resolve(%{"error" => reason}), do: {:error, {:settings_unavailable, reason}}
  def resolve(%{"agent" => ""}), do: :automatic

  def resolve(%{"agent" => name, "model" => model}) do
    case Enum.find(AgentRegistry.agents(), fn {agent, _} -> Atom.to_string(agent) == name end) do
      nil -> {:error, :unknown_agent}
      {agent, module} -> eligible(agent, module, model)
    end
  end

  @spec eligible(atom(), module(), term()) :: {:ok, module()} | {:error, term()}
  defp eligible(agent, module, model) do
    cond do
      not Settings.reviewer_eligible?(agent) -> {:error, :reviewer_ineligible}
      not AgentRegistry.installed?(module) -> {:error, :not_installed}
      not AgentRegistry.available?(module) -> {:error, :agent_unavailable}
      model in [nil, ""] -> {:error, :model_required}
      not ModelAvailability.available?(agent, model) -> {:error, :model_unavailable}
      true -> {:ok, module}
    end
  end

  @doc "Returns the explicit model only for its selected adapter."
  @spec model(atom()) :: String.t() | nil
  def model(agent) do
    saved = settings()
    if saved["agent"] == Atom.to_string(agent), do: saved["model"], else: Config.agent_model(agent)
  end

  @doc false
  @spec model_for(map(), String.t()) :: String.t() | nil
  def model_for(%{"agent" => name, "model" => model}, name), do: model

  def model_for(_saved, name) do
    case Enum.find(AgentRegistry.agents(), fn {agent, _} -> Atom.to_string(agent) == name end) do
      {agent, _} -> Config.agent_model(agent)
      nil -> nil
    end
  end

  @doc "Lists bounded selection facts for the QA controls, including unavailable candidates."
  @spec status() :: map()
  def status do
    saved = settings()

    options =
      Enum.map(AgentRegistry.agents(), fn {agent, module} ->
        model = Config.agent_model(agent)
        %{agent: Atom.to_string(agent), model: model, result: eligible(agent, module, model)}
      end)

    %{settings: saved, result: resolve(saved), options: options}
  end
end
