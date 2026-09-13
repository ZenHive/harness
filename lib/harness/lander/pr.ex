defmodule Harness.Lander.PR do
  @moduledoc """
  `:pr` landing helpers: open a GitHub pull request after the detached rebase,
  persist `pr_url`, and keep the rmap task `in_progress` until merge.
  """

  alias Harness.Lander.GH
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Run.LogRecord

  require Logger

  @doc """
  Opens the PR for `request` against `target` and records the URL.

  A missing or unauthenticated `gh` is returned as an error — the caller must
  not fall back to pushing the target. An rmap binary that rejects
  `--landing-ref` is logged and tolerated.
  """
  @spec open(Project.t(), map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, GH.error()}
  def open(%Project{} = project, request, target, repo) when is_binary(target) and is_binary(repo) do
    with {:ok, url} <- GH.create_pr(create_opts(project, request, target, repo)) do
      persist_opened(request.run_id, url)
      write_landing_ref(project, request, url)
      {:ok, url}
    end
  end

  @doc false
  @spec complete_merge(LogRecord.t(), String.t()) :: :ok | {:error, term()}
  def complete_merge(%LogRecord{} = record, sha) when is_binary(sha) do
    with {:ok, project} <- ProjectRegistry.lookup(record.project_name) do
      Harness.Lander.writeback_merged(project, request_from_record(record, project), sha)
      persist_writeback(record.run_id, :merged)
      :ok
    end
  end

  @doc false
  @spec complete_closed(LogRecord.t()) :: :ok | {:error, term()}
  def complete_closed(%LogRecord{} = record) do
    reason = "PR #{record.pr_url} closed unmerged"

    case mark_blocked(record, reason) do
      {:ok, _output} -> :ok
      {:error, mark_reason} -> log_blocked_failure(record, reason, mark_reason)
    end

    persist_writeback(record.run_id, :closed)
    notify_closed(record, reason)
    :ok
  end

  @spec create_opts(Project.t(), map(), String.t(), String.t()) :: keyword()
  defp create_opts(_project, request, target, repo) do
    [
      repo: repo,
      base: target,
      head: request.branch,
      title: pr_title(request),
      body: pr_body(request)
    ]
  end

  @spec pr_title(map()) :: String.t()
  defp pr_title(%{task_title: title}) when is_binary(title) and title != "", do: title
  defp pr_title(request), do: "harness " <> request.run_id

  @spec pr_body(map()) :: String.t()
  defp pr_body(request) do
    [
      request_body(request),
      acceptance_section(request),
      reviewer_section(request),
      "harness-run:" <> request.run_id
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec request_body(map()) :: String.t()
  defp request_body(%{task_body: body}) when is_binary(body), do: String.trim(body)
  defp request_body(_request), do: ""

  @spec acceptance_section(map()) :: String.t()
  defp acceptance_section(%{acceptance_criteria: criteria}) when is_list(criteria) and criteria != [] do
    bullets = Enum.map_join(criteria, "\n", &("- " <> &1))
    "## Acceptance criteria\n\n" <> bullets
  end

  defp acceptance_section(_request), do: ""

  @spec reviewer_section(map()) :: String.t()
  defp reviewer_section(%{review_report: report}) when is_binary(report) and report != "" do
    "## Reviewer report\n\n" <> report
  end

  defp reviewer_section(_request), do: ""

  @spec persist_opened(String.t(), String.t()) :: :ok
  defp persist_opened(run_id, url) do
    case ResultStore.mark_pr_url(run_id, url) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness lander: pr_url writeback failed for run #{run_id}: #{inspect(reason)}")
        :ok
    end
  end

  @spec persist_writeback(String.t(), atom()) :: :ok
  defp persist_writeback(run_id, status) do
    case ResultStore.mark_pr_writeback(run_id, status) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness lander: pr_writeback #{status} failed for run #{run_id}: #{inspect(reason)}")

        :ok
    end
  end

  @spec write_landing_ref(Project.t(), map(), String.t()) :: :ok
  defp write_landing_ref(project, request, url) do
    request
    |> landed_task_ids()
    |> Enum.each(&write_landing_ref_task(project, request, url, &1))

    :ok
  end

  @spec landed_task_ids(map()) :: [String.t()]
  defp landed_task_ids(%{task_ids: ids}) when is_list(ids) and ids != [], do: ids
  defp landed_task_ids(request), do: [request.task_id]

  @spec write_landing_ref_task(Project.t(), map(), String.t(), String.t()) :: :ok
  defp write_landing_ref_task(project, request, url, task_id) do
    case Roadmap.mark_in_progress(task_id, project: project, landing_ref: url) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "harness lander: landing-ref writeback failed: task_id=#{task_id} run_id=#{request.run_id} " <>
            "reason=#{inspect(reason)} (pr_url #{url} recorded; continuing)"
        )

        :ok
    end
  end

  @spec mark_blocked(LogRecord.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp mark_blocked(record, reason) do
    case ProjectRegistry.lookup(record.project_name) do
      {:ok, project} -> Roadmap.mark_blocked(record.task_id, project: project, reason: reason)
      {:error, _reason} = error -> error
    end
  end

  @spec log_blocked_failure(LogRecord.t(), String.t(), term()) :: :ok
  defp log_blocked_failure(record, reason, mark_reason) do
    Logger.error(
      "harness lander: failed to mark task #{record.task_id} blocked (#{inspect(mark_reason)}); reason was: #{reason}"
    )

    :ok
  end

  @spec notify_closed(LogRecord.t(), String.t()) :: :ok
  defp notify_closed(record, reason) do
    Notification.notify(%Event{
      type: :blocked,
      task_id: record.task_id,
      run_id: record.run_id,
      project: record.project_name,
      branch: "harness/" <> record.run_id,
      outcome: reason
    })
  end

  @spec request_from_record(LogRecord.t(), Project.t()) :: map()
  defp request_from_record(%LogRecord{} = record, %Project{} = project) do
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
end
