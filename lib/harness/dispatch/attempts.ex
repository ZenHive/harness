defmodule Harness.Dispatch.Attempts do
  @moduledoc "Raw persisted attempt and retained Git branch facts for dispatch planning."

  import Ecto.Query

  alias Harness.Git
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Run.LogRecord

  @doc "Attaches project-scoped history without treating unavailable storage as an empty history."
  @spec attach(Project.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def attach(%Project{} = project, tasks) do
    with :ok <- storage_enabled(),
         {:ok, records} <- ResultStore.list_run_records(project_name: project.name, strict_history: true) do
      {:ok,
       Enum.map(tasks, fn task ->
         attempts =
           records
           |> Enum.filter(&(to_string(task["id"]) in Enum.uniq([&1.task_id | membership(&1) || []])))
           |> Enum.map(&facts(project, &1))

         task
         |> Map.put("task_fingerprint", Roadmap.task_fingerprint(task))
         |> Map.put("attempts", attempts)
       end)}
    end
  end

  @doc "Reads a retained branch and origin ancestry, preserving Git errors as evidence."
  @spec facts(Project.t(), LogRecord.t()) :: map()
  def facts(%Project{} = project, %LogRecord{} = record) do
    %{
      "run_id" => record.run_id,
      "project_name" => record.project_name,
      "task_id" => record.task_id,
      "task_ids" => membership(record),
      "task_fingerprint" => record.task_fingerprint,
      "state" => record.state,
      "reason" => inspect(record.reason),
      "agent" => record.agent,
      "model" => record.model,
      "verdict" => record.verdict,
      "agent_diff_size" => record.agent_diff_size,
      "reviewer_diff_size" => record.reviewer_diff_size,
      "review_report" => record.review_report,
      "agent_outcome_kind" => record.agent_outcome_kind,
      "agent_exit_status" => record.agent_exit_status,
      "reviewer_outcome_kind" => record.reviewer_outcome_kind,
      "reviewer_exit_status" => record.reviewer_exit_status,
      "review_checks" => record.review_checks,
      "review_concerns" => record.review_concerns,
      "landed_sha" => record.landed_sha,
      "branch" => "harness/" <> record.run_id,
      "git" => branch_facts(project, record.run_id)
    }
  end

  @doc "Reads durable coalesced membership, including legacy jobs that predate the record column."
  @spec membership(LogRecord.t()) :: [String.t()] | nil
  def membership(%LogRecord{task_ids: [_ | _] = ids}), do: ids

  def membership(%LogRecord{} = record) do
    if Process.whereis(Harness.Repo) do
      query =
        from job in Oban.Job,
          where: fragment("?->>? = ?", job.args, "run_id", ^record.run_id),
          where: fragment("?->>? = ?", job.args, "project_name", ^record.project_name),
          limit: 1,
          select: job.args

      case Harness.Repo.one(query) do
        %{"item_ids" => ids} when is_list(ids) -> ids
        %{"item_id" => id} -> [id]
        _other -> nil
      end
    end
  rescue
    _error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] -> nil
  end

  @doc "Resolves the selected branch tip and fetches the authoritative origin target."
  @spec selection(Project.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def selection(%Project{target_branch: target} = project, run_id) when is_binary(target) and target != "" do
    with {:ok, repo} <- Project.local_repo_path(project),
         :ok <- Git.fetch_origin(repo),
         {:ok, tip} <- resolve(repo, "refs/heads/harness/" <> run_id),
         {:ok, origin} <- resolve(repo, "refs/remotes/origin/" <> target),
         {:ok, landed} <- ancestor(repo, tip, origin) do
      {:ok, %{"selected_sha" => tip, "origin_sha" => origin, "on_origin" => landed}}
    end
  end

  def selection(%Project{}, _run_id), do: {:error, :missing_target_branch}

  @spec storage_enabled() :: :ok | {:error, term()}
  defp storage_enabled do
    if ResultStore.configured() in [nil, false], do: {:error, :history_store_disabled}, else: :ok
  end

  @spec branch_facts(Project.t(), String.t()) :: map()
  defp branch_facts(project, run_id) do
    case selection(project, run_id) do
      {:ok, facts} -> facts
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp resolve(repo, ref) do
    case Git.run(["rev-parse", "--verify", ref <> "^{commit}"], repo) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} = error -> error
    end
  end

  @spec ancestor(String.t(), String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  defp ancestor(repo, tip, origin) do
    case Git.run(["merge-base", "--is-ancestor", tip, origin], repo) do
      {:ok, _output} -> {:ok, true}
      {:error, {:git_failed, _args, 1, _output}} -> {:ok, false}
      {:error, _reason} = error -> error
    end
  end
end
