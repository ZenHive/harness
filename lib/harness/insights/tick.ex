defmodule Harness.Insights.Tick do
  @moduledoc "Schedules enabled observations independently of dispatch autonomy."
  use Oban.Worker, queue: :cron, max_attempts: 1

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    status = Harness.Insights.status()

    if status["settings"]["enabled"] and due?(status["next_pass"]) do
      case Harness.Insights.observe_now() do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  @spec due?(String.t()) :: boolean()
  defp due?(next) do
    {:ok, date, _} = DateTime.from_iso8601(next)
    DateTime.compare(date, DateTime.utc_now()) != :gt
  end
end
