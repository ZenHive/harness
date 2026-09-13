defmodule Harness.Lander.PRPoller do
  @moduledoc """
  Cron worker that reads GitHub PR state for open harness pull requests.

  Mechanical only: `gh pr view --json state,mergeCommit,mergedAt`. MERGED
  completes the deferred `:auto` writeback (rmap `done --shipped-in`, post-merge
  audit, `:landed` event). CLOSED without a merge commit marks the task `blocked`
  with the PR URL in the reason and retains the branch. OPEN is a no-op. A run
  is written back at most once.
  """

  use Oban.Worker, queue: :cron, max_attempts: 1

  alias Harness.Cron.Settings
  alias Harness.Lander
  alias Harness.Lander.GH
  alias Harness.Lander.PR
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Oban.Cron

  require Logger

  @cron_queue :cron
  @view_fields ["state", "mergeCommit", "mergedAt"]

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{}) do
    case ResultStore.list_run_records([]) do
      {:ok, records} ->
        records
        |> Enum.filter(&open_pr?/1)
        |> Enum.each(&poll_one/1)

        :ok

      {:error, reason} ->
        Logger.warning("harness pr poller: list_run_records failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc false
  @spec cron_entry() :: {String.t(), module(), keyword()}
  def cron_entry do
    {schedule(), __MODULE__, [queue: @cron_queue, max_attempts: 1]}
  end

  @doc false
  @spec cron_plugin() :: {module(), keyword()}
  def cron_plugin do
    {Cron, crontab: [cron_entry()], timezone: HarnessOban.cron_timezone()}
  end

  @doc "Returns the persisted PR-poll crontab, defaulting to every 5 minutes."
  @spec schedule() :: String.t()
  def schedule, do: Settings.pr_poll_schedule()

  @doc false
  @spec open_pr?(LogRecord.t()) :: boolean()
  def open_pr?(%LogRecord{pr_url: url, landed_sha: sha, pr_writeback: status}) do
    is_binary(url) and url != "" and is_nil(sha) and status in [nil, :opened]
  end

  @spec poll_one(LogRecord.t()) :: :ok
  defp poll_one(%LogRecord{} = record) do
    repo = poll_repo(record)

    case GH.view(record.pr_url, @view_fields, repo: repo) do
      {:ok, view} -> handle_view(record, view)
      {:error, reason} -> log_view_failure(record, reason)
    end
  end

  @spec handle_view(LogRecord.t(), map()) :: :ok
  defp handle_view(record, view) do
    case pr_state(view) do
      :open -> :ok
      :merged -> merge_once(record, merge_sha(view))
      :closed -> PR.complete_closed(record)
      :unknown -> :ok
    end
  end

  @spec merge_once(LogRecord.t(), String.t() | nil) :: :ok
  defp merge_once(_record, nil), do: :ok

  defp merge_once(%LogRecord{landed_sha: sha}, sha) when is_binary(sha) and sha != "" do
    :ok
  end

  defp merge_once(%LogRecord{} = record, sha) do
    case PR.complete_merge(record, sha) do
      :ok ->
        enqueue_audit(record, sha)
        notify_landed(record, sha)
        :ok

      {:error, reason} ->
        Logger.warning("harness pr poller: merge writeback failed for run #{record.run_id}: #{inspect(reason)}")

        :ok
    end
  end

  @spec pr_state(map()) :: :open | :merged | :closed | :unknown
  defp pr_state(%{"state" => state} = view) when is_binary(state) do
    case String.upcase(state) do
      "OPEN" -> :open
      "MERGED" -> :merged
      "CLOSED" -> if merge_sha(view), do: :merged, else: :closed
      _other -> :unknown
    end
  end

  defp pr_state(_view), do: :unknown

  @spec merge_sha(map()) :: String.t() | nil
  defp merge_sha(%{"mergeCommit" => %{"oid" => sha}}) when is_binary(sha) and sha != "", do: sha
  defp merge_sha(%{"mergeCommit" => sha}) when is_binary(sha) and sha != "", do: sha
  defp merge_sha(_view), do: nil

  @spec enqueue_audit(LogRecord.t(), String.t()) :: :ok
  defp enqueue_audit(%LogRecord{} = record, sha) do
    case ProjectRegistry.lookup(record.project_name) do
      {:ok, %Project{} = project} ->
        Lander.enqueue_pr_audit(project, request_from_record(record, project), sha)

      {:error, reason} ->
        Logger.warning("harness pr poller: audit enqueue skipped for run #{record.run_id}: #{inspect(reason)}")

        :ok
    end
  end

  @spec notify_landed(LogRecord.t(), String.t()) :: :ok
  defp notify_landed(record, sha) do
    Notification.notify(%Event{
      type: :landed,
      task_id: record.task_id,
      run_id: record.run_id,
      project: record.project_name,
      branch: "harness/" <> record.run_id,
      outcome: sha
    })
  end

  @spec request_from_record(LogRecord.t(), Project.t()) :: map()
  defp request_from_record(record, project) do
    %{
      project: project,
      run_id: record.run_id,
      task_id: record.task_id,
      task_fingerprint: record.task_fingerprint,
      agent: record.agent,
      reviewer: record.reviewer_adapter,
      branch: "harness/" <> record.run_id
    }
  end

  @spec poll_repo(LogRecord.t()) :: String.t() | nil
  defp poll_repo(%LogRecord{project_name: name}) when is_binary(name) do
    case ProjectRegistry.lookup(name) do
      {:ok, project} ->
        case Project.local_repo_path(project) do
          {:ok, path} -> path
          _skipped -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp poll_repo(_record), do: nil

  @spec log_view_failure(LogRecord.t(), term()) :: :ok
  defp log_view_failure(record, reason) do
    Logger.warning("harness pr poller: gh view failed for #{record.pr_url}: #{inspect(reason)}")
    :ok
  end
end
