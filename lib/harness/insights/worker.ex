defmodule Harness.Insights.Worker do
  @moduledoc "Dedicated serialized observation queue; retries retain the publication id."
  use Oban.Worker,
    queue: :insights,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker], states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: %{"pass_id" => id}}) do
    case Harness.Insights.observe(id) do
      {:error, :disabled} -> :ok
      other -> other
    end
  end

  @impl Oban.Worker
  @spec timeout(Oban.Job.t()) :: pos_integer()
  def timeout(_job), do: 240_000
end
