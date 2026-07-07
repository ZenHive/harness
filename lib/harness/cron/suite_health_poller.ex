defmodule Harness.Cron.SuiteHealthPoller do
  @moduledoc """
  Daily cron worker that records full-suite health-check witness facts per project.

  Runs on the shared `:cron` queue at a fixed daily schedule, independent of the
  roadmap-poller cadence. Harness counts exit codes and failing tests only —
  never gates dispatch on the result.
  """

  use Oban.Worker, queue: :cron, max_attempts: 1

  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth
  alias Oban.Plugins.Cron

  require Logger

  @cron_queue :cron
  @daily_schedule "0 0 * * *"

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    Enum.each(ProjectRegistry.list(), fn project ->
      case SuiteHealth.check_project(project) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("harness suite health cron: #{project.name} #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc false
  @spec cron_entry() :: {String.t(), module(), keyword()}
  def cron_entry do
    {schedule(), __MODULE__, [queue: @cron_queue, max_attempts: 1]}
  end

  @doc false
  @spec cron_plugin() :: {module(), keyword()}
  def cron_plugin do
    {Cron, crontab: [cron_entry()]}
  end

  @doc "Returns the fixed daily cron expression for suite-health checks."
  @spec schedule() :: String.t()
  def schedule, do: @daily_schedule
end
