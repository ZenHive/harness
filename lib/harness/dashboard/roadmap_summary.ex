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

  # Bound each per-project roadmap read so one slow/hung `rmap list` can't stall
  # the whole rollup. Overridable via `:roadmap_summary_timeout_ms` (test seam,
  # mirrors `:roadmap_list`).
  @summarize_timeout_ms 5_000

  @typedoc "A per-project roadmap rollup."
  @type summary :: %{
          open: non_neg_integer(),
          done: non_neg_integer(),
          total: non_neg_integer(),
          landed: %{optional(String.t()) => String.t()},
          blocked: MapSet.t(String.t())
        }

  @typedoc "Per-project summaries keyed by project name."
  @type summaries :: %{optional(String.t()) => summary()}

  @doc """
  Builds the per-project summary map keyed by project name.

  Per-project roadmap reads are independent cold-path shell-outs, so they run
  concurrently with a bounded timeout — N projects cost ~one shell-out of
  wall-clock, not N sequential spawns (the regression that made `/harness` take
  12-15s under active-run load). Ordered results zip back to their project, so a
  read that times out or crashes degrades to an empty summary (named correctly)
  rather than blocking or crashing the panel.
  """
  @spec for_projects([Project.t()]) :: %{optional(String.t()) => summary()}
  def for_projects(projects) when is_list(projects) do
    projects
    |> Task.async_stream(&summarize/1, timeout: summarize_timeout_ms(), on_timeout: :kill_task)
    |> Enum.zip(projects)
    |> Map.new(fn
      {{:ok, summary}, %Project{name: name}} -> {name, summary}
      {{:exit, _reason}, %Project{name: name}} -> {name, empty()}
    end)
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

  @doc """
  Whether the run's task is currently `blocked` in the roadmap — joining
  `project_name` + `task_id` against the summaries map. The dashboard gates the
  "Re-land" button on this (a land-cap-exhausted train marks the task `blocked`).
  """
  @spec blocked?(%{optional(String.t()) => summary()}, String.t() | nil, String.t() | nil) :: boolean()
  def blocked?(summaries, project_name, task_id) when is_binary(project_name) and is_binary(task_id) do
    summaries |> summary_for(project_name) |> Map.fetch!(:blocked) |> MapSet.member?(task_id)
  end

  def blocked?(_summaries, _project_name, _task_id), do: false

  @doc false
  @spec tally([map()]) :: summary()
  def tally(tasks) do
    Enum.reduce(tasks, empty(), fn task, acc ->
      acc |> bump_counts(task["status"]) |> bump_landed(task) |> bump_blocked(task)
    end)
  end

  @spec summarize_timeout_ms() :: pos_integer()
  defp summarize_timeout_ms do
    Application.get_env(:harness, :roadmap_summary_timeout_ms, @summarize_timeout_ms)
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

  @spec bump_blocked(summary(), map()) :: summary()
  defp bump_blocked(acc, %{"id" => id, "status" => "blocked"}) do
    %{acc | blocked: MapSet.put(acc.blocked, to_string(id))}
  end

  defp bump_blocked(acc, _task), do: acc

  @spec empty() :: summary()
  defp empty, do: %{open: 0, done: 0, total: 0, landed: %{}, blocked: MapSet.new()}
end
