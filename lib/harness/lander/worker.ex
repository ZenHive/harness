defmodule Harness.Lander.Worker do
  @moduledoc """
  Oban worker that lands one approved run onto its project's target branch.

  Enqueued by `Harness.Run` when a run settles green under a `landing_policy:
  :auto` project, onto the serialized `landing_<name>` queue (limit 1). Resolves
  the project from the registry **with the runtime landing override applied**
  (`Harness.Landing.Settings.overlay/1` — the dashboard's auto-land flip; the
  raw registry entry may still say `:manual` / no target branch), delegates to
  `Harness.Lander.land/1`, and hands the structured outcome to
  `Harness.Lander.Resilience.route/2`, which maps it to Oban's worker contract —
  landing the run, re-dispatching/re-landing under the attempt cap, or marking
  the task `blocked` at the cap. The worker stays thin: build the request, land,
  route.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Harness.Lander
  alias Harness.Lander.Resilience
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ProjectRegistry

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    with {:ok, project_name} <- fetch_arg(args, "project_name"),
         {:ok, branch} <- fetch_arg(args, "branch"),
         {:ok, project} <- ProjectRegistry.lookup(project_name) do
      %{
        project: LandingSettings.overlay(project),
        run_id: args["run_id"],
        task_id: args["task_id"],
        agent: args["agent"],
        branch: branch
      }
      |> Lander.land()
      |> Resilience.route(args)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  @spec fetch_arg(map(), String.t()) :: {:ok, String.t()} | {:error, {:missing_arg, String.t()}}
  defp fetch_arg(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_arg, key}}
    end
  end
end
