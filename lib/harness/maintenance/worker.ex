defmodule Harness.Maintenance.Worker do
  @moduledoc "Serialized maintenance jobs with stable pass identities and bounded deadlines."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:project],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: %{"project" => project, "pass_id" => id}}) do
    case Harness.Maintenance.sweep(project, id) do
      {:error, :disabled} -> :ok
      {:error, :already_sweeping} -> {:snooze, 60}
      result -> result
    end
  end

  @impl Oban.Worker
  @spec timeout(Oban.Job.t()) :: pos_integer()
  def timeout(%Oban.Job{args: %{"project" => project}}),
    do: Harness.Maintenance.settings(project)["deadline_seconds"] * 1000
end
