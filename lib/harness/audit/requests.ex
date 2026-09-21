defmodule Harness.Audit.Requests do
  @moduledoc "Operator QA requests through the existing audit queue."

  import Ecto.Query

  alias Harness.Audit.QAAttempt
  alias Harness.Audit.Worker
  alias Harness.Git
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Repo

  @waiting_states ["available", "scheduled", "retryable"]

  @doc "Enqueues a recheck, coalescing equivalent active requests while retaining newer work."
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(name, opts \\ []) do
    with {:ok, project} <- ProjectRegistry.lookup(name),
         :ok <- require_qa(project),
         {:ok, repo} <- Project.local_repo_path(project),
         {:ok, target} <- Project.target_branch(project),
         {:ok, revision} <- remote_revision(repo, target) do
      insert_request(name, project.qa_command, target, revision, opts)
    else
      {:skipped, reason} -> {:error, reason}
      {:error, _} = error -> error
    end
  rescue
    error in [RuntimeError, ArgumentError, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, {:queue_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:queue_unavailable, reason}}
  end

  @spec require_qa(Project.t()) :: :ok | {:error, :qa_not_configured}
  defp require_qa(%Project{qa_command: command}) when is_binary(command) do
    if String.trim(command) == "", do: {:error, :qa_not_configured}, else: :ok
  end

  defp require_qa(_project), do: {:error, :qa_not_configured}

  @spec remote_revision(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp remote_revision(repo, target) do
    case Git.run(["ls-remote", "--exit-code", "origin", "refs/heads/" <> target], repo) do
      {:ok, output} -> parse_revision(output)
      error -> error
    end
  end

  @spec parse_revision(String.t()) :: {:ok, String.t()} | {:error, :target_revision_unavailable}
  defp parse_revision(output) do
    case String.split(output) do
      [revision, _ref | _] -> {:ok, revision}
      _ -> {:error, :target_revision_unavailable}
    end
  end

  @spec insert_request(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  defp insert_request(name, command, target, revision, opts) do
    args = %{
      "project_name" => name,
      "base_sha" => revision,
      "qa_revision" => revision,
      "qa_command" => command,
      "qa_target" => target
    }

    unique = [
      keys: [:project_name, :qa_revision, :qa_command, :qa_target],
      period: :infinity,
      states: [:available, :scheduled, :retryable, :executing]
    ]

    Repo.transaction(fn -> persist_request(args, opts, unique) end)
  end

  @spec persist_request(map(), keyword(), keyword()) :: Oban.Job.t()
  defp persist_request(args, opts, unique) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["qa-request:" <> args["project_name"]])
    args |> existing_audit() |> write_job(args, opts, unique)
  end

  @spec write_job(Oban.Job.t() | nil, map(), keyword(), keyword()) :: Oban.Job.t()
  defp write_job(nil, args, opts, unique) do
    accept_job(Oban.insert(Keyword.get(opts, :oban, Harness.Oban), Worker.new(args, unique: unique)))
  end

  defp write_job(job, _args, _opts, _unique), do: accept_job({:ok, %{job | conflict?: true}})

  @spec accept_job({:ok, term()} | {:error, term()}) :: Oban.Job.t()
  defp accept_job({:ok, %{id: id} = job}) when is_integer(id), do: job
  defp accept_job({:error, reason}), do: Repo.rollback(reason)

  @spec existing_audit(map()) :: Oban.Job.t() | nil
  defp existing_audit(args), do: waiting_audit(args) || running_audit(args)

  @spec waiting_audit(map()) :: Oban.Job.t() | nil
  defp waiting_audit(args) do
    Repo.one(
      from(j in Oban.Job,
        where: j.worker == "Harness.Audit.Worker" and j.args["project_name"] == ^args["project_name"],
        where: j.state in ^@waiting_states,
        where:
          is_nil(j.args["qa_revision"]) or
            (j.args["qa_revision"] == ^args["qa_revision"] and j.args["qa_command"] == ^args["qa_command"] and
               j.args["qa_target"] == ^args["qa_target"]),
        order_by: [asc: j.id],
        limit: 1
      )
    )
  end

  @spec running_audit(map()) :: Oban.Job.t() | nil
  defp running_audit(args) do
    Repo.one(
      from(j in Oban.Job,
        join: a in QAAttempt,
        on: a.job_id == j.id and a.attempt == j.attempt,
        where: j.worker == "Harness.Audit.Worker" and j.args["project_name"] == ^args["project_name"],
        where: j.state == "executing" and a.status == "running",
        where:
          a.revision == ^args["qa_revision"] and a.command == ^args["qa_command"] and
            a.target_branch == ^args["qa_target"],
        order_by: [asc: j.id],
        limit: 1,
        select: j
      )
    )
  end
end
