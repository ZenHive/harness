defmodule Harness.Maintenance.Tick do
  @moduledoc "Schedules opted-in repositories independently of dispatch policy."
  use Oban.Worker, queue: :cron, max_attempts: 1

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    Enum.reduce_while(Harness.ProjectRegistry.list(), :ok, &schedule/2)
  end

  @spec schedule(Harness.Project.t(), :ok) :: {:cont, :ok} | {:halt, term()}
  defp schedule(project, :ok) do
    status = Harness.Maintenance.status(project.name)

    if status["settings"]["enabled"] and status["next_sweep"] <= DateTime.to_iso8601(DateTime.utc_now()) do
      case Harness.Maintenance.sweep_now(project.name) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    else
      {:cont, :ok}
    end
  end
end
