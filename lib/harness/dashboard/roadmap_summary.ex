defmodule Harness.Dashboard.RoadmapSummary do
  @moduledoc """
  Per-project roadmap rollup for the dashboard index (read-only).

  Answers two operator questions the run tables alone can't:

    * **How much roadmap is left?** — `open` / `done` / `total` task counts per
      registered project, tallied from `Harness.Roadmap.list/2`.
    * **Did a run actually land?** — a `task_id => shipped_in` map built from the
      tasks the merge-train lander marked `done` with a commit SHA (the
      `Harness.Lander` writeback). The index joins a settled run's `task_id`
      against this map to badge the run as landed.

  Both come from one `rmap list --json` per project — a cold-path shell-out, so
  the index reads it once at mount and refreshes on a slow tick, never per run
  event. A project whose roadmap can't be read (unregistered path, `{:github,_}`
  source not cloned, rmap error) contributes an empty summary rather than
  crashing the panel.

  `superseded` tasks are excluded from every count — they are dead, not open
  work — so `total` is `open + done`, the live task corpus.

  ## Test seam

  `Application.get_env(:harness, :roadmap_list)`, when set to a
  `(Harness.Project.t() -> {:ok, [map()]} | {:error, term()})` function, replaces
  the real `Harness.Roadmap.list/2` call — mirroring `RoadmapPoller`'s
  `:roadmap_ready` seam so the panel is testable without a live roadmap on disk.
  """

  alias Harness.Project
  alias Harness.Roadmap

  @open_statuses ~w(pending in_progress blocked)

  @typedoc "A per-project roadmap rollup."
  @type summary :: %{
          open: non_neg_integer(),
          done: non_neg_integer(),
          total: non_neg_integer(),
          landed: %{optional(String.t()) => String.t()}
        }

  @typedoc "Per-project summaries keyed by project name."
  @type summaries :: %{optional(String.t()) => summary()}

  @doc "Builds the per-project summary map keyed by project name."
  @spec for_projects([Project.t()]) :: %{optional(String.t()) => summary()}
  def for_projects(projects) when is_list(projects) do
    Map.new(projects, fn %Project{name: name} = project -> {name, summarize(project)} end)
  end

  @doc "Returns the summary for `name`, or a zero summary when absent."
  @spec summary_for(%{optional(String.t()) => summary()}, String.t()) :: summary()
  def summary_for(summaries, name), do: Map.get(summaries, name) || empty()

  @doc """
  The landed commit SHA for a run, joining `project_name` + `task_id` against the
  summaries map. Returns the SHA when the task has landed (the lander recorded a
  `shipped_in`), else `nil`.
  """
  @spec landed_sha(%{optional(String.t()) => summary()}, String.t() | nil, String.t() | nil) ::
          String.t() | nil
  def landed_sha(summaries, project_name, task_id) when is_binary(project_name) and is_binary(task_id) do
    summaries |> summary_for(project_name) |> Map.fetch!(:landed) |> Map.get(task_id)
  end

  def landed_sha(_summaries, _project_name, _task_id), do: nil

  @doc false
  @spec tally([map()]) :: summary()
  def tally(tasks) do
    Enum.reduce(tasks, empty(), fn task, acc ->
      acc |> bump_counts(task["status"]) |> bump_landed(task)
    end)
  end

  @spec summarize(Project.t()) :: summary()
  defp summarize(%Project{} = project) do
    case list_tasks(project) do
      {:ok, tasks} when is_list(tasks) -> tally(tasks)
      _other -> empty()
    end
  end

  @spec list_tasks(Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp list_tasks(%Project{name: name} = project) do
    case Application.get_env(:harness, :roadmap_list) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.list(name)
    end
  end

  @spec bump_counts(summary(), term()) :: summary()
  defp bump_counts(acc, status) when status in @open_statuses, do: %{acc | open: acc.open + 1, total: acc.total + 1}

  defp bump_counts(acc, "done"), do: %{acc | done: acc.done + 1, total: acc.total + 1}
  defp bump_counts(acc, _superseded_or_unknown), do: acc

  @spec bump_landed(summary(), map()) :: summary()
  defp bump_landed(acc, %{"id" => id, "shipped_in" => sha}) when is_binary(sha) and sha != "" do
    %{acc | landed: Map.put(acc.landed, to_string(id), sha)}
  end

  defp bump_landed(acc, _task), do: acc

  @spec empty() :: summary()
  defp empty, do: %{open: 0, done: 0, total: 0, landed: %{}}
end
