defmodule Harness.Lander.Worker do
  @moduledoc """
  Oban worker that lands one approved run onto its project's target branch.

  Enqueued by `Harness.Run` when a run settles green under a `landing_policy`
  in `[:auto, :pr]` project, onto the serialized `landing_<name>` queue (limit
  1). Resolves the project from `Harness.ProjectRegistry.lookup/1`, which
  returns the **effective** project with the runtime landing override already
  applied (the dashboard's auto-land / PR flip; the registration default may
  still say `:manual` / no target branch). Delegates to `Harness.Lander.land/1`
  and hands the structured outcome to `Harness.Lander.Resilience.route/2`,
  which maps it to Oban's worker contract — landing the run, opening a PR,
  re-dispatching/re-landing under the attempt cap, or marking the task
  `blocked` at the cap. The worker stays thin: build the request, land, route.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Harness.Lander
  alias Harness.Lander.Resilience
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectRegistry

  @doc """
  Builds this worker's Oban job for `args` on `project`'s serialized
  `landing_<name>` queue (limit 1) — the queue that makes landing a merge
  train. Every landing enqueue goes through here so no call site can target
  the wrong queue.
  """
  @spec new_for_project(map(), Project.t()) :: Ecto.Changeset.t()
  def new_for_project(args, %Project{} = project) when is_map(args) do
    new(args, queue: HarnessOban.landing_queue_name(project))
  end

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    with {:ok, project_name} <- fetch_arg(args, "project_name"),
         {:ok, branch} <- fetch_arg(args, "branch"),
         {:ok, run_id} <- fetch_arg(args, "run_id"),
         {:ok, task_id} <- fetch_arg(args, "task_id"),
         {:ok, project} <- ProjectRegistry.lookup(project_name) do
      project
      |> request_from_args(args, branch, run_id, task_id)
      |> Lander.land()
      |> Resilience.route(args)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  @spec request_from_args(Project.t(), map(), String.t(), String.t(), String.t()) :: Lander.request()
  defp request_from_args(project, args, branch, run_id, task_id) do
    %{
      project: project,
      run_id: run_id,
      task_id: task_id,
      task_fingerprint: args["task_fingerprint"],
      task_ids: args["task_ids"],
      task_fingerprints: args["task_fingerprints"],
      agent: args["agent"],
      reviewer: args["reviewer"],
      branch: branch,
      task_title: optional_string(args["task_title"]),
      task_body: optional_string(args["task_body"]),
      acceptance_criteria: wrap_criteria(args["acceptance_criteria"]),
      review_report: optional_string(args["review_report"])
    }
  end

  @spec optional_string(term()) :: String.t() | nil
  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_other), do: nil

  @spec wrap_criteria(term()) :: [String.t()]
  defp wrap_criteria(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp wrap_criteria(_other), do: []

  @spec fetch_arg(map(), String.t()) :: {:ok, String.t()} | {:error, {:missing_arg, String.t()}}
  defp fetch_arg(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_arg, key}}
    end
  end
end
