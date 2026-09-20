defmodule Harness.Dispatch.Resolution do
  @moduledoc "Project, adapter, model, and capability resolution for dispatch."

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Registry
  alias Harness.CapabilityScore
  alias Harness.Config
  alias Harness.Dispatch.Presentation
  alias Harness.ModelAvailability
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Roadmap.Item

  @recommended_adapter "recommend"

  @spec recommend(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @doc false
  def recommend(domain, opts \\ []) when is_binary(domain) and is_list(opts) do
    with {:ok, domain} <- parse_domain(domain) do
      facets = Keyword.get(opts, :facets, CapabilityScore.facets_from_domain(domain))
      CapabilityScore.recommend(facets, opts)
    end
  end

  @spec assess_facets(keyword()) :: {:ok, map()} | {:error, term()}
  @doc false
  def assess_facets(opts \\ []) when is_list(opts) do
    case CapabilityScore.refresh(opts) do
      {:ok, assessment} -> {:ok, Presentation.summarize_assessment(assessment)}
      {:error, _reason} = error -> error
    end
  end

  # The single resolve → ingest pipeline shared by enqueue_start/4 and start/5,
  # so the adapter-resolution + render logic exists exactly once: a bug fix here
  # is one edit, not four. The `recommend` sentinel ingests for claude, scores a
  # recommendation off the item, then re-renders for the chosen agent; a concrete
  # adapter resolves first and ingests rendered for that agent directly.
  @spec resolve_and_ingest(String.t(), String.t(), String.t()) ::
          {:ok, {Project.t(), Item.t(), module()}} | {:error, Harness.Dispatch.error()}
  @doc false
  def resolve_and_ingest(project_name, task, @recommended_adapter) do
    with {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: :claude),
         {:ok, {adapter_module, render_agent}} <- recommended_adapter_for_item(@recommended_adapter, item),
         {:ok, item} <- rerender_for_agent(item, project, render_agent),
         :ok <- ensure_model_available(adapter_module, render_agent, item, task) do
      {:ok, {project, item, adapter_module}}
    end
  end

  @doc false
  def resolve_and_ingest(project_name, task, adapter) do
    with {:ok, {adapter_module, render_agent}} <- resolve_adapter(adapter),
         {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: render_agent),
         :ok <- ensure_model_available(adapter_module, render_agent, item, task) do
      {:ok, {project, item, adapter_module}}
    end
  end

  # Fail fast before a run/worktree spins up: a model-capable agent with no
  # resolved model (no task pin, no `{:agent_model, agent}` default) is rejected
  # outright — harness never falls through to the agent CLI's ambient default.
  @spec ensure_model_available(module(), atom(), Item.t(), String.t()) :: :ok | {:error, Harness.Dispatch.error()}
  defp ensure_model_available(adapter, agent, %Item{} = item, task) do
    model = effective_model(item, agent)

    cond do
      is_nil(model) and AgentAdapter.requires_model?(adapter) ->
        {:error, {:model_required, agent}}

      ModelAvailability.available?(agent, model) ->
        :ok

      true ->
        ModelAvailability.notify_blocked_dispatch(agent, model, task)
        {:error, {:unavailable, agent, model, available: ModelAvailability.list_available_ids(agent)}}
    end
  end

  # A task's pinned model belongs to its pinned assignee. When a dispatch resolves
  # to a DIFFERENT agent than the pin (an explicit-adapter override, or — before the
  # precedence fix — a recommend/default override), carrying the pinned model yields
  # an agent+model pair that's invalid or budget-capped (cursor + gpt-6-astra, cursor +
  # grok-4.5). So a pinned model applies only on its own assignee's adapter; a
  # cross-agent dispatch uses the resolved agent's configured default instead. A
  # model pin with no assignee has no agent to contradict it, so it carries through.
  @spec effective_model(Item.t(), atom()) :: String.t() | nil
  @doc false
  def effective_model(%Item{model: model, assignee: assignee}, agent)
      when is_binary(model) and (is_nil(assignee) or assignee == agent), do: model

  @doc false
  def effective_model(_item, agent) do
    Config.agent_model(agent)
  end

  @spec recommended_adapter_for_item(String.t(), Item.t(), keyword()) ::
          {:ok, {module(), atom()}} | {:error, term()}
  @doc false
  def recommended_adapter_for_item(adapter, item, opts \\ [])

  @doc false
  def recommended_adapter_for_item(@recommended_adapter, %Item{assignee: assignee} = item, opts) when is_list(opts) do
    # Precedence: a task's roadmap-pinned `assignee` ALWAYS wins over the global
    # `dispatch.default_agent`. Capability scoring (and the default-agent fallback
    # inside it) only fills the gap when the task carries no pin — otherwise a
    # no-`adapter` dispatch would silently override an explicit codex/grok pin with
    # the default cursor, carrying the pinned model onto the wrong adapter.
    case assignee do
      nil ->
        item
        |> predict_facets()
        |> CapabilityScore.recommend(opts)
        |> case do
          {:ok, %{agent: agent}} -> resolve_adapter(Atom.to_string(agent))
          {:error, _reason} = error -> error
        end

      agent ->
        resolve_adapter(Atom.to_string(agent))
    end
  end

  @doc false
  def recommended_adapter_for_item(adapter, %Item{}, opts) when is_binary(adapter) and is_list(opts) do
    resolve_adapter(adapter)
  end

  @spec rerender_for_agent(Item.t(), Project.t(), atom()) :: {:ok, Item.t()} | {:error, Harness.Dispatch.error()}
  defp rerender_for_agent(%Item{agent: agent} = item, _project, agent), do: {:ok, item}

  defp rerender_for_agent(%Item{} = item, %Project{} = project, render_agent) do
    Roadmap.ingest({:id, item.id}, project: project, agent: render_agent)
  end

  @spec predict_facets(Item.t()) :: map()
  defp predict_facets(%Item{domains: [domain | _]}), do: CapabilityScore.facets_from_domain(domain)

  defp predict_facets(%Item{}), do: %{}

  # Bundle dispatch is Oban-backed and resolves each job's executor from the
  # ingested item's render agent. rmap renders natively for all six adapters, so
  # all six pass; the guard remains in case a future adapter is registered
  # without a matching `delegate --to` target (see Registry.delegatable?/1).
  @spec resolve_delegatable_adapter(String.t()) ::
          {:ok, {module(), atom()}} | {:error, {:unknown_adapter | :non_delegatable_adapter, String.t()}}
  @doc false
  def resolve_delegatable_adapter(adapter) do
    case resolve_adapter(adapter) do
      {:ok, pair} ->
        if Registry.delegatable?(adapter),
          do: {:ok, pair},
          else: {:error, {:non_delegatable_adapter, adapter}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec effective_model_for_adapter(module(), atom(), Item.t()) :: String.t() | nil
  @doc false
  def effective_model_for_adapter(adapter, agent, %Item{} = item) do
    model = effective_model(item, agent)

    if is_nil(model) or AgentAdapter.model_supported?(adapter, model),
      do: model,
      else: Config.agent_model(agent)
  end

  @spec resolve_adapter(String.t()) :: {:ok, {module(), atom()}} | {:error, {:unknown_adapter, String.t()}}
  @doc false
  def resolve_adapter(adapter), do: Registry.resolve(adapter)

  @spec parse_domain(String.t()) :: {:ok, atom()} | {:error, {:unknown_domain, String.t()}}
  defp parse_domain(":" <> domain), do: parse_domain(domain)

  # Domains are part of harness's static atom vocabulary; do not create atoms
  # from arbitrary MCP input.
  defp parse_domain(domain) do
    {:ok, String.to_existing_atom(domain)}
  rescue
    ArgumentError -> {:error, {:unknown_domain, domain}}
  end

  @spec lookup_project(String.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t()}}
  @doc false
  def lookup_project(project_name) do
    case ProjectRegistry.lookup(project_name) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _} -> {:error, {:unknown_project, project_name}}
    end
  end

  @spec selector(String.t()) :: Roadmap.selector()
  @doc false
  def selector("next"), do: :next

  @doc false
  def selector(id), do: {:id, id}
end
