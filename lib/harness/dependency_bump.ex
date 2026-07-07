defmodule Harness.DependencyBump do
  @moduledoc """
  Operator-triggered dependency-bump dispatch through the normal agent gate.

  This module creates ordinary rmap tasks from stored dependency-freshness facts
  and enqueues them through `Harness.Run.Worker`. It never runs dependency
  update commands or tests itself; the implementer and reviewer agents do that.
  """

  alias Harness.AgentAdapter.Registry
  alias Harness.DependencyBump.Providers
  alias Harness.DependencyBump.TaskSpec
  alias Harness.DepFreshness
  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.Dispatch.AgentGate
  alias Harness.Project

  @default_phase 1
  @default_scores %{d: 3, b: 7, u: 7}

  @type result :: %{
          project_name: String.t(),
          tasks: [map()]
        }

  @type error ::
          {:unknown_project, String.t()}
          | {:unknown_adapter, String.t()}
          | {:snapshot_not_found, String.t()}
          | {:no_supported_providers, [atom()]}
          | {:rmap_failed, [String.t()], integer(), String.t()}
          | {:rmap_spawn_failed, [String.t()], term()}
          | {:rmap_bad_output, term()}
          | term()

  @doc "Create dependency-bump rmap tasks from freshness facts and enqueue reviewer-gated runs."
  @spec dispatch(String.t(), String.t(), String.t() | nil, boolean()) :: {:ok, result()} | {:error, error()}
  def dispatch(project_name, adapter \\ "codex", model \\ nil, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(adapter) and (is_nil(model) or is_binary(model)) and
             is_boolean(scrub_anthropic_key) do
    with {:ok, project} <- lookup_project(project_name),
         {:ok, adapter_pair} <- Registry.resolve(adapter),
         {:ok, snapshot} <- fetch_snapshot(project_name),
         {:ok, specs} <- build_task_specs(project, snapshot),
         {:ok, tasks} <-
           AgentGate.create_and_enqueue(project, specs, adapter, model,
             creator: task_creator(),
             enqueuer: enqueuer(),
             adapter_pair: adapter_pair,
             scrub: scrub_anthropic_key,
             build_result: &build_result/3
           ) do
      {:ok, %{project_name: project.name, tasks: tasks}}
    end
  end

  @doc false
  @spec build_task_specs(Project.t(), Snapshot.t()) :: {:ok, [TaskSpec.t()]} | {:error, error()}
  def build_task_specs(%Project{} = project, %Snapshot{} = snapshot) do
    specs =
      project
      |> Providers.resolve()
      |> Enum.flat_map(&provider_specs(&1, snapshot.rows))

    if specs == [] do
      {:ok, []}
    else
      {:ok, specs}
    end
  end

  @spec provider_specs(Providers.resolution(), [Row.t()]) :: [TaskSpec.t()]
  defp provider_specs({:ok, language, provider}, rows) do
    language_rows =
      Enum.filter(rows, fn row ->
        row.language in [nil, language] and Row.outdated?(row)
      end)

    provider.build(language, language_rows)
  end

  defp provider_specs({:skipped, _language, _reason}, _rows), do: []

  @spec lookup_project(String.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t()}}
  defp lookup_project(project_name), do: AgentGate.lookup_project(project_name)

  @spec fetch_snapshot(String.t()) :: {:ok, Snapshot.t()} | {:error, {:snapshot_not_found, String.t()} | term()}
  defp fetch_snapshot(project_name) do
    case DepFreshness.fetch_snapshot(project_name) do
      {:ok, %Snapshot{} = snapshot} -> {:ok, snapshot}
      {:error, :not_found} -> {:error, {:snapshot_not_found, project_name}}
      {:error, _reason} = error -> error
    end
  end

  @spec build_result(TaskSpec.t(), String.t(), String.t()) :: map()
  defp build_result(%TaskSpec{} = spec, task_id, run_id) do
    %{
      task_id: task_id,
      run_id: run_id,
      language: spec.language,
      kind: spec.kind,
      dependencies: Enum.map(spec.rows, & &1.name),
      check_command: spec.check_command
    }
  end

  @spec task_creator() :: AgentGate.task_creator()
  defp task_creator do
    AgentGate.task_creator(:dependency_bump_task_creator, &create_rmap_tasks/4)
  end

  @spec enqueuer() :: AgentGate.enqueuer()
  defp enqueuer do
    AgentGate.enqueuer(:dependency_bump_enqueuer)
  end

  @spec create_rmap_tasks(Project.t(), [TaskSpec.t()], String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, error()}
  defp create_rmap_tasks(%Project{} = project, specs, adapter, model) do
    AgentGate.run_rmap_new(project, task_toml(project, specs, adapter, model))
  end

  @spec task_toml(Project.t(), [TaskSpec.t()], String.t(), String.t() | nil) :: String.t()
  defp task_toml(%Project{} = project, specs, adapter, model) do
    {phase, bundle} = roadmap_bucket(project)

    Enum.map_join(specs, "\n", &task_block(&1, phase, bundle, adapter, model))
  end

  @spec task_block(TaskSpec.t(), pos_integer(), String.t(), String.t(), String.t() | nil) :: String.t()
  defp task_block(%TaskSpec{} = spec, phase, bundle, adapter, model) do
    AgentGate.task_block(
      phase: phase,
      bundle: bundle,
      scores: @default_scores,
      title: spec.title,
      body: spec.body,
      acceptance_criteria: spec.acceptance_criteria,
      files_to_modify: spec.files_to_modify,
      adapter: adapter,
      model: model
    )
  end

  @spec roadmap_bucket(Project.t()) :: {pos_integer(), String.t()}
  defp roadmap_bucket(%Project{} = project) do
    case bundle_resolver().(project) do
      {:ok, {phase, bundle}} -> {phase, bundle}
      _fallback -> {@default_phase, "deferred"}
    end
  end

  @spec bundle_resolver() :: (Project.t() -> {:ok, {pos_integer(), String.t()}} | {:error, term()})
  defp bundle_resolver do
    Application.get_env(:harness, :dependency_bump_bundle_resolver, &resolve_bundle/1)
  end

  @spec resolve_bundle(Project.t()) :: {:ok, {pos_integer(), String.t()}} | {:error, error()}
  defp resolve_bundle(%Project{} = project) do
    args = ["bundles", "--json", "--tasks-path", AgentGate.tasks_path(project)]

    case System.cmd("rmap", args, cd: project.roadmap_path, stderr_to_stdout: true) do
      {output, 0} -> parse_bundle(output)
      {output, status} -> {:error, {:rmap_failed, args, status, output}}
    end
  end

  @spec parse_bundle(String.t()) :: {:ok, {pos_integer(), String.t()}} | {:error, {:rmap_bad_output, term()}}
  defp parse_bundle(output) do
    with {:ok, %{"bundles" => [_ | _] = bundles}} <- Jason.decode(output),
         %{"name" => name, "phase" => phase} <- choose_bundle(bundles),
         true <- is_binary(name),
         true <- is_integer(phase) do
      {:ok, {phase, name}}
    else
      {:ok, other} -> {:error, {:rmap_bad_output, other}}
      {:error, reason} -> {:error, {:rmap_bad_output, reason}}
      _other -> {:error, {:rmap_bad_output, output}}
    end
  end

  @spec choose_bundle([map()]) :: map() | nil
  defp choose_bundle(bundles) do
    Enum.find(bundles, &(&1["in_focus"] == true)) || Enum.find(bundles, &pending_bundle?/1) || List.first(bundles)
  end

  @spec pending_bundle?(map()) :: boolean()
  defp pending_bundle?(%{"status_counts" => %{"pending" => pending}}) when is_integer(pending), do: pending > 0
  defp pending_bundle?(_bundle), do: false
end
