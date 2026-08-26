defmodule Harness.Cron.DepFreshnessPoller do
  @moduledoc """
  Cron worker that records dependency freshness facts for registered projects.

  Runs on the shared `:cron` queue schedule. Each tick invokes the per-language
  providers keyed on `project.languages` and persists raw rows — no judgment,
  no auto-update, never a gate.
  """

  use Oban.Worker, queue: :cron, max_attempts: 1

  alias Harness.Cron.Settings
  alias Harness.DepFreshness
  alias Harness.ProjectRegistry
  alias Oban.Cron

  require Logger

  @cron_queue :cron

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    Enum.each(ProjectRegistry.list(), fn project ->
      case DepFreshness.scan_project(project) do
        :ok -> :ok
        {:skipped, _reason} -> :ok
        {:error, reason} -> Logger.warning("harness dep freshness cron: #{project.name} #{inspect(reason)}")
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

  @doc "Returns the configured cron expression (shared with roadmap polling)."
  @spec schedule() :: String.t()
  def schedule, do: Settings.schedule()
end
