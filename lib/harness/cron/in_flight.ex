defmodule Harness.Cron.InFlight do
  @moduledoc """
  Mechanical in-flight dispatch identity for cron.

  Registry is authoritative for in-BEAM live runs; Oban is authoritative for
  persisted queued/executing jobs. Count both by `{project, task_id}`, not by
  rmap status and not by `run_id`. A settled run is not in-flight regardless of
  an `in_progress` rmap row — that stickiness is Task 131 (manual landing), and
  this module is the consumer that must not misread it as occupancy.
  """

  alias Harness.Project
  alias Harness.Roadmap
  alias Harness.Run.Status

  @in_flight_run_states [:dispatched, :running, :committing, :recovering, :reviewing, :held]
  @live_status_timeout_ms 100

  @typedoc "Occupancy facts counted for a poll. `rmap_in_progress` is `:unread` when the roadmap cannot be listed."
  @type snapshot :: %{
          cap: pos_integer() | nil,
          occupancy: non_neg_integer(),
          rmap_in_progress: non_neg_integer() | :unread,
          tasks: [map()]
        }

  @doc """
  Returns whether `{project, item_id}` already has a live run or an unfinished
  Oban run job.

  The same dispatch identity `Harness.Cron.RoadmapPoller` uses to skip a
  duplicate enqueue.
  """
  @spec run_in_flight?(Project.t(), String.t()) :: boolean()
  def run_in_flight?(%Project{} = project, item_id) when is_binary(item_id) do
    live_run_in_flight?(project, item_id) or Harness.Oban.unfinished_run_job?(project, item_id)
  end

  @doc """
  In-flight tasks for the orchestrator context, with rmap `touches` /
  `files_to_modify` resolved onto each live id.

  A live id with no matching rmap row is still returned as `%{"id" => id}` so
  occupancy is not dropped when path data is missing.
  """
  @spec tasks(Project.t()) :: [map()]
  def tasks(%Project{} = project) do
    snapshot(project).tasks
  end

  @doc """
  Counts the project's configured cap, live/unfinished occupancy, and rmap
  `in_progress` rows as three separate facts — no derived diagnosis.
  """
  @spec snapshot(Project.t()) :: snapshot()
  def snapshot(%Project{} = project) do
    {rows, rmap_in_progress} = rmap_rows(project)
    tasks = resolve(project, rows)

    %{
      cap: project.concurrency_cap,
      occupancy: length(tasks),
      rmap_in_progress: rmap_in_progress,
      tasks: tasks
    }
  end

  @spec rmap_rows(Project.t()) :: {[map()], non_neg_integer() | :unread}
  defp rmap_rows(%Project{} = project) do
    case rmap_list(project) do
      {:ok, rows} when is_list(rows) -> {rows, Enum.count(rows, &in_progress?/1)}
      _other -> {[], :unread}
    end
  end

  @spec resolve(Project.t(), [map()]) :: [map()]
  defp resolve(%Project{} = project, rows) do
    by_id = Map.new(rows, &{task_id(&1), &1})

    project
    |> in_flight_ids()
    |> Enum.map(fn id -> Map.get(by_id, id, %{"id" => id}) end)
  end

  @spec in_flight_ids(Project.t()) :: [String.t()]
  defp in_flight_ids(%Project{} = project) do
    project
    |> live_task_ids()
    |> Enum.concat(Harness.Oban.unfinished_run_task_ids(project))
    |> Enum.uniq()
  end

  @spec live_task_ids(Project.t()) :: [String.t()]
  defp live_task_ids(%Project{} = project) do
    for %Status{} = status <- live_run_statuses(),
        matching_live_run?(status, project, status.task_id),
        do: status.task_id
  end

  @spec live_run_in_flight?(Project.t(), String.t()) :: boolean()
  defp live_run_in_flight?(%Project{} = project, item_id) do
    Enum.any?(live_run_statuses(), &matching_live_run?(&1, project, item_id))
  end

  @spec matching_live_run?(Status.t(), Project.t(), String.t()) :: boolean()
  defp matching_live_run?(%Status{} = status, %Project{} = project, item_id) do
    status.project_name == project.name and status.task_id == item_id and status.state in @in_flight_run_states
  end

  @spec live_run_statuses() :: [Status.t()]
  defp live_run_statuses do
    case Application.get_env(:harness, :live_run_statuses) do
      fun when is_function(fun, 0) -> fun.()
      _other -> live_run_statuses_from_registry()
    end
  end

  @spec live_run_statuses_from_registry() :: [Status.t()]
  defp live_run_statuses_from_registry do
    Enum.flat_map(Harness.Run.Supervisor.list_runs(), &run_status/1)
  end

  @spec run_status(String.t()) :: [Status.t()]
  defp run_status(run_id) do
    case Harness.Run.status(run_id, @live_status_timeout_ms) do
      {:ok, %Status{} = status} -> [status]
      {:error, _reason} -> []
    end
  end

  @spec rmap_list(Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp rmap_list(%Project{name: name} = project) do
    case Application.get_env(:harness, :roadmap_list) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.list(name)
    end
  end

  @spec in_progress?(map()) :: boolean()
  defp in_progress?(task), do: to_string(task["status"]) == "in_progress"

  @spec task_id(map()) :: String.t()
  defp task_id(task), do: to_string(task["id"])
end
