defmodule Harness.Audit.Requests do
  @moduledoc "Operator QA requests through the existing audit queue."

  import Ecto.Query

  alias Harness.Audit.QAAttempt
  alias Harness.Audit.Worker
  alias Harness.Git
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Repo

  @doc "Enqueues a recheck, coalescing equivalent active requests while retaining newer work."
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(name, opts \\ []) do
    with {:ok, project} <- ProjectRegistry.lookup(name),
         true <- (is_binary(project.qa_command) and String.trim(project.qa_command) != "") || {:error, :qa_not_configured},
         {:ok, repo} <- Project.local_repo_path(project),
         {:ok, target} <- Project.target_branch(project),
         {:ok, output} <- Git.run(["ls-remote", "--exit-code", "origin", "refs/heads/" <> target], repo),
         [revision, _ref] <- String.split(output) do
      args = %{
        "project_name" => name,
        "base_sha" => revision,
        "qa_revision" => revision,
        "qa_command" => project.qa_command,
        "qa_target" => target
      }

      unique = [
        keys: [:project_name, :qa_revision, :qa_command, :qa_target],
        period: :infinity,
        states: [:available, :scheduled, :retryable, :executing]
      ]

      Repo.transaction(fn ->
        # Serialize operator submissions across BEAM nodes, including Oban testing mode.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["qa-request:" <> name])

        result =
          case existing_audit(args) do
            nil -> Oban.insert(Keyword.get(opts, :oban, Harness.Oban), Worker.new(args, unique: unique))
            job -> {:ok, %{job | conflict?: true}}
          end

        case result do
          {:ok, %{id: id} = job} when is_integer(id) -> job
          {:ok, _} -> Repo.rollback(:queue_busy)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:skipped, reason} -> {:error, reason}
      {:error, _} = error -> error
      _ -> {:error, :target_revision_unavailable}
    end
  rescue
    error in [RuntimeError, ArgumentError, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, {:queue_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:queue_unavailable, reason}}
  end

  @spec existing_audit(map()) :: Oban.Job.t() | nil
  defp existing_audit(args) do
    Repo.one(
      from(j in Oban.Job,
        left_join: a in QAAttempt,
        on: a.job_id == j.id and a.attempt == j.attempt,
        where: j.worker == "Harness.Audit.Worker" and j.args["project_name"] == ^args["project_name"],
        where:
          (j.state in ["available", "scheduled", "retryable"] and is_nil(j.args["qa_revision"])) or
            (j.state == "executing" and a.status == "running" and a.revision == ^args["qa_revision"] and
               a.command == ^args["qa_command"] and a.target_branch == ^args["qa_target"]),
        order_by: [asc: j.id],
        limit: 1,
        select: j
      )
    )
  end
end
