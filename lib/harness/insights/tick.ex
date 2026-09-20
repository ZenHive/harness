defmodule Harness.Insights.Tick do
  @moduledoc "Schedules enabled observations independently of dispatch autonomy."
  use Oban.Worker, queue: :cron, max_attempts: 1

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    status = Harness.Insights.status()

    if status["settings"]["enabled"] and Harness.Cron.Due.due?(status["next_pass"]) do
      case Harness.Insights.observe_now() do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end
end
