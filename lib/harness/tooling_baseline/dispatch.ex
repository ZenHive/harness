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
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run.Worker, as: RunWorker
  alias Harness.ToolingBaseline.Providers
  alias Harness.ToolingBaseline.Snapshot
  alias Harness.ToolingBaseline.TaskSpec

  @default_phase 1
  @default_bundle "operator-surface"
  @default_scores %{d: 3, b: 6, u: 6}
  @task_id_line_regex ~r/created task(?:s)? (.+)/

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
         {:ok, task_ids} <- create_tasks(project, specs, adapter, model),
         {:ok, tasks} <- enqueue_tasks(project, specs, task_ids, adapter_pair, scrub_anthropic_key) do
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
  defp lookup_project(project_name) do
    case ProjectRegistry.lookup(project_name) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _reason} -> {:error, {:unknown_project, project_name}}
    end
  end

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

  @spec create_tasks(Project.t(), [TaskSpec.t()], String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, error()}
  defp create_tasks(%Project{}, [], _adapter, _model), do: {:ok, []}

  defp create_tasks(%Project{} = project, specs, adapter, model) do
    case task_creator().(project, specs, adapter, model) do
      {:ok, task_ids} when is_list(task_ids) -> {:ok, Enum.map(task_ids, &to_string/1)}
      {:error, _reason} = error -> error
    end
  end

  @spec enqueue_tasks(Project.t(), [TaskSpec.t()], [String.t()], {module(), atom()}, boolean()) ::
          {:ok, [map()]} | {:error, error()}
  defp enqueue_tasks(%Project{}, [], [], _adapter_pair, _scrub), do: {:ok, []}

  defp enqueue_tasks(%Project{} = project, specs, task_ids, {adapter_module, render_agent}, scrub) do
    specs
    |> Enum.zip(task_ids)
    |> Enum.reduce_while({:ok, []}, fn {spec, task_id}, {:ok, acc} ->
      case enqueue_task(project, spec, task_id, adapter_module, render_agent, scrub) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      {:error, _reason} = error -> error
    end
  end

  @spec enqueue_task(Project.t(), TaskSpec.t(), String.t(), module(), atom(), boolean()) ::
          {:ok, map()} | {:error, error()}
  defp enqueue_task(%Project{} = project, %TaskSpec{} = spec, task_id, adapter_module, render_agent, scrub) do
    with {:ok, item} <- ingest_task(task_id, project, render_agent),
         {:ok, run_id, _job} <-
           enqueuer().(project, item, adapter_module,
             env: scrub_env(scrub),
             check_command: spec.check_command,
             requested_model: item.model
           ) do
      {:ok,
       %{
         task_id: task_id,
         run_id: run_id,
         language: spec.language,
         kind: spec.kind,
         missing: Enum.map(spec.items, & &1.id),
         skipped_languages: spec.skipped_languages,
         check_command: spec.check_command
       }}
    end
  end

  @spec ingest_task(String.t(), Project.t(), atom()) :: {:ok, Item.t()} | {:error, error()}
  defp ingest_task(task_id, %Project{} = project, render_agent) do
    case Application.get_env(:harness, :roadmap_ingest) do
      fun when is_function(fun, 2) -> fun.({:id, task_id}, project: project, agent: render_agent)
      _other -> Roadmap.ingest({:id, task_id}, project: project, agent: render_agent)
    end
  end

  @spec task_creator() :: (Project.t(), [TaskSpec.t()], String.t(), String.t() | nil ->
                             {:ok, [String.t()]} | {:error, term()})
  defp task_creator do
    Application.get_env(:harness, :tooling_baseline_task_creator, &create_rmap_tasks/4)
  end

  @spec enqueuer() :: (Project.t(), Item.t(), module(), keyword() -> {:ok, String.t(), Oban.Job.t()} | {:error, term()})
  defp enqueuer do
    Application.get_env(:harness, :tooling_baseline_enqueuer, &RunWorker.enqueue/4)
  end

  @spec create_rmap_tasks(Project.t(), [TaskSpec.t()], String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, error()}
  defp create_rmap_tasks(%Project{} = project, specs, adapter, model) do
    args = ["new", "--from-stdin", "--tasks-path", tasks_path(project)]
    input = task_toml(specs, adapter, model)

    case System.cmd("rmap", args, input: input, cd: project.roadmap_path, stderr_to_stdout: true) do
      {output, 0} -> parse_created_ids(output)
      {output, status} -> {:error, {:rmap_failed, args, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:rmap_spawn_failed, ["new", "--from-stdin"], Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:rmap_spawn_failed, ["new", "--from-stdin"], reason}}
  end

  @spec task_toml([TaskSpec.t()], String.t(), String.t() | nil) :: String.t()
  defp task_toml(specs, adapter, model) do
    Enum.map_join(specs, "\n", &task_block(&1, adapter, model))
  end

  @spec task_block(TaskSpec.t(), String.t(), String.t() | nil) :: String.t()
  defp task_block(%TaskSpec{} = spec, adapter, model) do
    [
      "[[task]]",
      "phase = #{@default_phase}",
      "bundle = #{toml_string(@default_bundle)}",
      "title = #{toml_string(spec.title)}",
      "scores = { d = #{@default_scores.d}, b = #{@default_scores.b}, u = #{@default_scores.u} }",
      assignee_line(adapter),
      model_line(model),
      "body = #{toml_string(spec.body)}",
      "acceptance_criteria = #{toml_array(spec.acceptance_criteria)}",
      "files_to_modify = #{toml_array(spec.files_to_modify)}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @spec parse_created_ids(String.t()) :: {:ok, [String.t()]} | {:error, {:rmap_bad_output, String.t()}}
  defp parse_created_ids(output) do
    ids =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&created_ids_from_line/1)

    if ids == [], do: {:error, {:rmap_bad_output, output}}, else: {:ok, ids}
  end

  @spec created_ids_from_line(String.t()) :: [String.t()]
  defp created_ids_from_line(line) do
    case Regex.run(@task_id_line_regex, line, capture: :all_but_first) do
      [ids] -> ids |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      _none -> []
    end
  end

  @spec tasks_path(Project.t()) :: String.t()
  defp tasks_path(%Project{} = project), do: Path.join(project.roadmap_path, "roadmap/tasks.toml")

  @spec assignee_line(String.t()) :: String.t()
  defp assignee_line("recommend"), do: ""
  defp assignee_line(adapter), do: "assignee = #{toml_string(adapter)}"

  @spec model_line(String.t() | nil) :: String.t()
  defp model_line(nil), do: ""
  defp model_line(model), do: "model = #{toml_string(model)}"

  @spec toml_string(String.t()) :: String.t()
  defp toml_string(value) when is_binary(value), do: Jason.encode!(value)

  @spec toml_array([String.t()]) :: String.t()
  defp toml_array(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &toml_string/1) <> "]"
  end

  @spec scrub_env(boolean()) :: %{optional(String.t()) => false}
  defp scrub_env(true), do: %{"ANTHROPIC_API_KEY" => false}
  defp scrub_env(false), do: %{}
end
