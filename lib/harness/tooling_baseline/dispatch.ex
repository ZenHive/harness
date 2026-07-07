defmodule Harness.ToolingBaseline.Dispatch do
  @moduledoc """
  Operator-triggered tooling-baseline dispatch through the normal agent gate.

  This module creates ordinary rmap tasks from stored baseline-conformance facts
  and enqueues them through `Harness.Run.Worker`. It never installs tooling or
  runs project checks itself; the implementer and reviewer agents do that.
  """

  alias Harness.AgentAdapter.Registry
  alias Harness.DepFreshness
  alias Harness.DepFreshness.Snapshot, as: FreshnessSnapshot
  alias Harness.Dispatch.AgentGate
  alias Harness.Project
  alias Harness.ToolingBaseline.Providers
  alias Harness.ToolingBaseline.Snapshot
  alias Harness.ToolingBaseline.TaskSpec

  @default_phase 1
  @default_bundle "operator-surface"
  @default_scores %{d: 3, b: 6, u: 6}

  @type result :: %{
          project_name: String.t(),
          tasks: [map()],
          skipped_languages: [TaskSpec.skipped_language()]
        }

  @type error ::
          {:unknown_project, String.t()}
          | {:unknown_adapter, String.t()}
          | {:snapshot_not_found, String.t()}
          | {:missing_conformance_snapshot, String.t()}
          | {:rmap_failed, [String.t()], integer(), String.t()}
          | {:rmap_spawn_failed, [String.t()], term()}
          | {:rmap_bad_output, term()}
          | term()

  @doc "Create tooling-baseline rmap tasks from conformance facts and enqueue reviewer-gated runs."
  @spec dispatch(String.t(), String.t(), String.t() | nil, boolean()) :: {:ok, result()} | {:error, error()}
  def dispatch(project_name, adapter \\ "codex", model \\ nil, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(adapter) and (is_nil(model) or is_binary(model)) and
             is_boolean(scrub_anthropic_key) do
    with {:ok, project} <- lookup_project(project_name),
         {:ok, adapter_pair} <- Registry.resolve(adapter),
         {:ok, snapshot} <- fetch_conformance(project_name),
         {:ok, specs, skipped} <- build_task_specs(project, snapshot),
         {:ok, tasks} <-
           AgentGate.create_and_enqueue(project, specs, adapter, model,
             creator: task_creator(),
             enqueuer: enqueuer(),
             adapter_pair: adapter_pair,
             scrub: scrub_anthropic_key,
             build_result: &build_result/3
           ) do
      {:ok, %{project_name: project.name, tasks: tasks, skipped_languages: skipped}}
    end
  end

  @doc false
  @spec build_task_specs(Project.t(), Snapshot.t()) ::
          {:ok, [TaskSpec.t()], [TaskSpec.skipped_language()]} | {:error, error()}
  def build_task_specs(%Project{} = project, %Snapshot{} = snapshot) do
    resolutions = Providers.resolve(project)
    skipped = skipped_languages(resolutions)

    specs =
      resolutions
      |> Enum.flat_map(&provider_specs(&1, project, snapshot, skipped))
      |> Enum.reject(&is_nil/1)

    {:ok, specs, skipped}
  end

  @spec provider_specs(Providers.resolution(), Project.t(), Snapshot.t(), [TaskSpec.skipped_language()]) ::
          [TaskSpec.t() | nil]
  defp provider_specs({:ok, _language, provider}, project, snapshot, skipped) do
    [provider.build_task_spec(project, snapshot, skipped_languages: skipped)]
  end

  defp provider_specs({:skipped, _language, _reason}, _project, _snapshot, _skipped), do: []

  @spec skipped_languages([Providers.resolution()]) :: [TaskSpec.skipped_language()]
  defp skipped_languages(resolutions) do
    Enum.flat_map(resolutions, fn
      {:skipped, language, reason} -> [%{language: language, reason: reason}]
      {:ok, _language, _provider} -> []
    end)
  end

  @spec lookup_project(String.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t()}}
  defp lookup_project(project_name), do: AgentGate.lookup_project(project_name)

  @spec fetch_conformance(String.t()) ::
          {:ok, Snapshot.t()}
          | {:error, {:snapshot_not_found, String.t()} | {:missing_conformance_snapshot, String.t()} | term()}
  defp fetch_conformance(project_name) do
    case DepFreshness.fetch_snapshot(project_name) do
      {:ok, %FreshnessSnapshot{conformance: %Snapshot{} = snapshot}} -> {:ok, snapshot}
      {:ok, %FreshnessSnapshot{}} -> {:error, {:missing_conformance_snapshot, project_name}}
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
      missing: Enum.map(spec.items, & &1.id),
      skipped_languages: spec.skipped_languages,
      check_command: spec.check_command
    }
  end

  @spec task_creator() :: AgentGate.task_creator()
  defp task_creator do
    AgentGate.task_creator(:tooling_baseline_task_creator, &create_rmap_tasks/4)
  end

  @spec enqueuer() :: AgentGate.enqueuer()
  defp enqueuer do
    AgentGate.enqueuer(:tooling_baseline_enqueuer)
  end

  @spec create_rmap_tasks(Project.t(), [TaskSpec.t()], String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, error()}
  defp create_rmap_tasks(%Project{} = project, specs, adapter, model) do
    AgentGate.run_rmap_new(project, task_toml(specs, adapter, model))
  end

  @spec task_toml([TaskSpec.t()], String.t(), String.t() | nil) :: String.t()
  defp task_toml(specs, adapter, model) do
    Enum.map_join(specs, "\n", &task_block(&1, adapter, model))
  end

  @spec task_block(TaskSpec.t(), String.t(), String.t() | nil) :: String.t()
  defp task_block(%TaskSpec{} = spec, adapter, model) do
    AgentGate.task_block(
      phase: @default_phase,
      bundle: @default_bundle,
      scores: @default_scores,
      title: spec.title,
      body: spec.body,
      acceptance_criteria: spec.acceptance_criteria,
      files_to_modify: spec.files_to_modify,
      adapter: adapter,
      model: model
    )
  end
end
