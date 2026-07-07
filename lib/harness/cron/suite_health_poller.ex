defmodule Harness.Cron.SuiteHealthPoller do
  @moduledoc """
  Daily cron worker that records full-suite health-check witness facts per project.

  Runs on its own `:suite_health` queue (limit 1) at a fixed daily schedule so
  long full-suite runs never occupy the shared `:cron` queue slot the roadmap
  and dep-freshness pollers tick on. Harness counts exit codes and failing
  tests only — never gates dispatch on the result.
  """

  use Oban.Worker, queue: :suite_health, max_attempts: 1

  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth
  alias Oban.Plugins.Cron

  require Logger

  @queue :suite_health
  @queue_limit 1
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
    {schedule(), __MODULE__, [queue: @queue, max_attempts: 1]}
  end

  @doc false
  @spec queue_config() :: {atom(), pos_integer()}
  def queue_config, do: {@queue, @queue_limit}

  @doc false
  @spec cron_plugin() :: {module(), keyword()}
  def cron_plugin do
    {Cron, crontab: [cron_entry()]}
  end

  @doc "Returns the fixed daily cron expression for suite-health checks."
  @spec schedule() :: String.t()
  def schedule, do: @daily_schedule
end
