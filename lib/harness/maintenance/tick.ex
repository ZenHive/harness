defmodule Harness.Maintenance.Tick do
  @moduledoc "Schedules opted-in repositories independently of dispatch policy."
  use Oban.Worker, queue: :cron, max_attempts: 1

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    Enum.each(Harness.ProjectRegistry.list(), &schedule/1)
    :ok
  end

  @spec schedule(Harness.Project.t()) :: :ok
  defp schedule(project) do
    status = Harness.Maintenance.status(project.name)

    if status["settings"]["enabled"] and due?(status["next_sweep"]) do
      _ = Harness.Maintenance.sweep_now(project.name)
    end

    :ok
  end

  @spec due?(term()) :: boolean()
  defp due?(next) when is_binary(next) do
    case DateTime.from_iso8601(next) do
      {:ok, date, _} -> DateTime.compare(date, DateTime.utc_now()) != :gt
      _ -> false
    end
  end

  defp due?(_), do: false
end
