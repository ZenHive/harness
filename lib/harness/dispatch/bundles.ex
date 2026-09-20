defmodule Harness.Dispatch.Bundles do
  @moduledoc "Bundle and coalesced dispatch with dependency and write-set serialization."

  alias Harness.Batch
  alias Harness.Dispatch.Resolution
  alias Harness.Dispatch.Submission
  alias Harness.Dispatch.WriteSetPlan
  alias Harness.Project
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run.Worker, as: RunWorker

  require Logger

  @recommended_adapter "recommend"

  @spec bundle(String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, Harness.Dispatch.error()}
  @doc false
  def bundle(project_name, adapter \\ "claude", scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(adapter) and is_boolean(scrub_anthropic_key) do
    with {:ok, fallback_pair} <- Resolution.resolve_delegatable_adapter(adapter),
         {:ok, project} <- Resolution.lookup_project(project_name),
         {:ok, %{bundle: bundle_meta, tasks: tasks}} <- next_bundle(project_name),
         plan = tasks |> dependency_ready_tasks() |> WriteSetPlan.plan(),
         dispatch_tasks = first_wave(plan),
         :ok <- log_serialized_bundle(project, plan),
         {:ok, items} <- ingest_bundle(dispatch_tasks, project, fallback_pair),
         {:ok, jobs} <-
           Batch.dispatch(project, items,
             env: Submission.scrub_env(scrub_anthropic_key),
             persist_requested_model: true
           ) do
      {:ok,
       %{
         bundle: bundle_meta,
         task_ids: Enum.map(items, & &1.id),
         job_ids: Enum.map(jobs, & &1.id),
         dispatched: length(jobs),
         serialized: serialized_plan(plan)
       }}
    end
  end

  @spec coalesce(String.t(), [String.t()], String.t(), boolean()) ::
          {:ok, map()} | {:error, Harness.Dispatch.error() | :invalid_task_ids}
  @doc false
  def coalesce(project_name, task_ids, adapter \\ @recommended_adapter, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_list(task_ids) and is_binary(adapter) and is_boolean(scrub_anthropic_key) do
    ids = task_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    with true <- match?([_, _ | _], ids) || {:error, :invalid_task_ids},
         {:ok, {adapter_module, render_agent}} <- Resolution.resolve_delegatable_adapter(adapter),
         {:ok, project} <- Resolution.lookup_project(project_name),
         {:ok, items} <- ingest_coalesced(ids, project, render_agent),
         item = Item.coalesce(items),
         {:ok, run_id, _job} <-
           RunWorker.enqueue_coalesced(project, item, adapter_module,
             env: Submission.scrub_env(scrub_anthropic_key),
             requested_model: Resolution.effective_model(item, render_agent)
           ) do
      {:ok, %{run_id: run_id, task_ids: item.task_ids, write_set: coalesced_write_set(project, item.task_ids)}}
    end
  end

  # Ingest each bundle task into a %Roadmap.Item{}, halting on the first failure.
  # rmap emits task ids as JSON (string or integer); coerce to the string id
  # `Roadmap.ingest({:id, _})` requires.
  @spec ingest_bundle([map()], Project.t(), {module(), atom()}) :: {:ok, [Item.t()]} | {:error, Harness.Dispatch.error()}
  defp ingest_bundle(tasks, project, fallback_pair) do
    tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, items} ->
      case ingest_bundle_task(task, project, fallback_pair) do
        {:ok, item} -> {:cont, {:ok, [item | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  # A coalesced run is ONE landing unit, so its write-set footprint is the union
  # of its members' — that union, not any single member's, is what the caller
  # must serialize the next wave against (harness never auto-selects what to
  # coalesce, so the orchestrator does the serializing and needs the union back).
  # Best-effort: an rmap read failure degrades to [] rather than failing a run
  # that is already enqueued, and logs so a silent [] is never mistaken for
  # "these tasks declare no files".
  @spec coalesced_write_set(Project.t(), [String.t()]) :: [String.t()]
  defp coalesced_write_set(%Project{} = project, task_ids) do
    case roadmap_list(project) do
      {:ok, tasks} ->
        ids = MapSet.new(task_ids)

        tasks
        |> Enum.filter(&MapSet.member?(ids, task_id(&1)))
        |> Enum.reduce(MapSet.new(), &MapSet.union(WriteSetPlan.write_set(&1), &2))
        |> Enum.sort()

      {:error, reason} ->
        Logger.warning(
          "harness dispatch coalesce: #{project.name} could not read the roadmap for the write-set union of tasks #{Enum.join(task_ids, ", ")}: #{inspect(reason)}"
        )

        []
    end
  end

  @spec roadmap_list(Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp roadmap_list(%Project{name: name} = project) do
    case Application.get_env(:harness, :roadmap_list) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.list(name)
    end
  end

  @spec ingest_coalesced([String.t()], Project.t(), atom()) :: {:ok, [Item.t()]} | {:error, Harness.Dispatch.error()}
  defp ingest_coalesced(ids, project, render_agent) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, items} ->
      case ingest_roadmap({:id, id}, project: project, agent: render_agent) do
        {:ok, item} -> {:cont, {:ok, [item | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  @spec ingest_bundle_task(map(), Project.t(), {module(), atom()}) :: {:ok, Item.t()} | {:error, Harness.Dispatch.error()}
  defp ingest_bundle_task(task, project, fallback_pair) do
    with {:ok, {adapter, render_agent}} <- bundle_adapter_for_task(task, fallback_pair),
         {:ok, item} <- ingest_roadmap({:id, task_id(task)}, project: project, agent: render_agent) do
      {:ok, %{item | model: Resolution.effective_model_for_adapter(adapter, render_agent, item)}}
    end
  end

  @spec bundle_adapter_for_task(map(), {module(), atom()}) ::
          {:ok, {module(), atom()}} | {:error, Harness.Dispatch.error()}
  defp bundle_adapter_for_task(%{"assignee" => assignee}, _fallback_pair)
       when is_binary(assignee) and assignee not in ["", "human"] do
    Resolution.resolve_delegatable_adapter(assignee)
  end

  defp bundle_adapter_for_task(_task, fallback_pair), do: {:ok, fallback_pair}

  @spec dependency_ready_tasks([map()]) :: [map()]
  defp dependency_ready_tasks(tasks) do
    non_done_ids =
      tasks
      |> Enum.reject(&done_task?/1)
      |> MapSet.new(&task_id/1)

    Enum.reject(tasks, &depends_on_non_done_task?(&1, non_done_ids))
  end

  @spec depends_on_non_done_task?(map(), MapSet.t(String.t())) :: boolean()
  defp depends_on_non_done_task?(task, non_done_ids) do
    task
    |> Map.get("depends_on", [])
    |> string_values()
    |> Enum.any?(&MapSet.member?(non_done_ids, &1))
  end

  @spec done_task?(map()) :: boolean()
  defp done_task?(%{"status" => status}) when status in ["done", :done], do: true

  defp done_task?(_task), do: false

  @spec string_values(term()) :: [String.t()]
  defp string_values(values) when is_list(values), do: Enum.map(values, &to_string/1)

  defp string_values(_values), do: []

  @spec task_id(map()) :: String.t()
  defp task_id(task), do: task |> Map.get("id") |> to_string()

  @spec next_bundle(String.t()) :: {:ok, %{bundle: map() | nil, tasks: [map()]}} | {:error, Harness.Dispatch.error()}
  defp next_bundle(project_name) do
    case Application.get_env(:harness, :roadmap_next_bundle) do
      fun when is_function(fun, 1) -> fun.(project_name)
      _other -> Roadmap.next_bundle(project_name)
    end
  end

  @spec ingest_roadmap(Roadmap.selector(), keyword()) :: {:ok, Item.t()} | {:error, Harness.Dispatch.error()}
  defp ingest_roadmap(selector, opts) do
    case Application.get_env(:harness, :roadmap_ingest) do
      fun when is_function(fun, 2) -> fun.(selector, opts)
      _other -> Roadmap.ingest(selector, opts)
    end
  end

  @spec first_wave(WriteSetPlan.t()) :: [map()]
  defp first_wave(%WriteSetPlan{waves: [wave | _rest]}), do: wave

  defp first_wave(%WriteSetPlan{waves: []}), do: []

  @spec serialized_plan(WriteSetPlan.t()) :: map()
  defp serialized_plan(%WriteSetPlan{} = plan) do
    %{
      waves: WriteSetPlan.wave_ids(plan.waves),
      collisions: plan.collisions
    }
  end

  @spec log_serialized_bundle(Project.t(), WriteSetPlan.t()) :: :ok
  defp log_serialized_bundle(%Project{} = _project, %WriteSetPlan{collisions: []}), do: :ok

  defp log_serialized_bundle(%Project{} = project, %WriteSetPlan{} = plan) do
    Enum.each(plan.collisions, fn collision ->
      Logger.info(
        "harness dispatch bundle: #{project.name} serialized tasks #{Enum.join(collision.task_ids, ", ")} on shared files #{Enum.join(collision.shared_files, ", ")}; dispatching wave #{inspect(hd(WriteSetPlan.wave_ids(plan.waves)))}"
      )
    end)
  end
end
