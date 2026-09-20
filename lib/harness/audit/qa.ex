defmodule Harness.Audit.QA do
  @moduledoc "Durable facts for full-project QA performed by the post-merge audit agent."

  import Ecto.Query

  alias Harness.Audit.QAAttempt
  alias Harness.Repo

  @db_errors [RuntimeError, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error]
  @type attempt :: QAAttempt.t()
  @worker "Harness.Audit.Worker"

  @doc "Starts an attempt, preserving earlier interrupted attempts and their pending range."
  @spec start(map()) :: {:ok, attempt()} | {:error, term()}
  def start(request) do
    project = request.project

    attrs = %{
      project_name: project.name,
      target_branch: project.target_branch,
      base_sha: request.base_sha,
      command: project.qa_command,
      status: "running",
      job_id: request[:job_id],
      attempt: request[:attempt]
    }

    Repo.transaction(fn ->
      if attrs.job_id do
        Repo.update_all(
          from(a in QAAttempt,
            where: a.job_id == ^attrs.job_id and a.status == "running" and a.attempt < ^attrs.attempt
          ),
          set: [status: "incomplete", updated_at: DateTime.utc_now()]
        )
      end

      case %QAAttempt{}
           |> Ecto.Changeset.change(attrs)
           |> Ecto.Changeset.unique_constraint([:job_id, :attempt])
           |> Repo.insert() do
        {:ok, attempt} -> attempt
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Returns the last successful revision, or the oldest still-pending base."
  @spec base(attempt()) :: String.t()
  def base(attempt) do
    scope =
      from(a in QAAttempt,
        where: a.project_name == ^attempt.project_name and a.target_branch == ^attempt.target_branch
      )

    passed =
      Repo.one(
        from(a in scope,
          where: a.status == "passed" and a.command == ^attempt.command,
          order_by: [desc: a.inserted_at],
          limit: 1,
          select: a.revision
        )
      )

    passed || Repo.one(from(a in scope, order_by: [asc: a.inserted_at], limit: 1, select: a.base_sha)) || attempt.base_sha
  end

  @doc "Pins the integrated revision, included commits and selected agent before invocation."
  @spec pin(attempt(), map()) :: {:ok, attempt()} | {:error, term()}
  def pin(attempt, attrs), do: attempt |> Ecto.Changeset.change(attrs) |> Repo.update()

  @doc "Persists the agent's judgment only when its report identifies the configured check and revision."
  @spec finish(attempt(), map(), term(), binary()) :: {:ok, attempt()} | {:error, term()}
  def finish(attempt, report, termination, transcript) do
    qa = Map.get(report, "qa", %{})
    status = report_status(attempt, qa, termination)
    pin(attempt, %{status: status, report: report, transcript: transcript})
  end

  @doc "Records an unfinished attempt without advancing successful QA progress."
  @spec incomplete(attempt(), term()) :: {:ok, attempt()} | {:error, term()}
  def incomplete(attempt, reason) do
    case Repo.get!(QAAttempt, attempt.id) do
      %{status: "running"} = current ->
        pin(current, %{status: "incomplete", report: %{"reason" => inspect(reason)}})

      current ->
        {:ok, current}
    end
  end

  @doc "Returns bounded attempt summaries and pending Oban jobs for a project."
  @spec list(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def list(project_name, limit \\ 20)

  def list(project_name, limit) when is_binary(project_name) and is_integer(limit) and limit in 1..100 do
    attempts =
      Repo.all(
        from(a in QAAttempt, where: a.project_name == ^project_name, order_by: [desc: a.inserted_at], limit: ^limit)
      )

    jobs =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.worker == ^@worker and j.args["project_name"] == ^project_name and
              j.state in ["available", "scheduled", "retryable", "executing"],
          order_by: [asc: j.id],
          limit: ^limit,
          select: %{job_id: j.id, state: j.state, base_sha: j.args["base_sha"]}
        )
      )

    {:ok,
     %{
       attempts: Enum.map(attempts, &summary/1),
       pending: Enum.map(jobs, &Map.put(&1, :status, if(&1.state == "executing", do: "running", else: "queued")))
     }}
  rescue
    error in @db_errors -> {:error, {:qa_unavailable, Exception.message(error)}}
  end

  def list(_project_name, _limit), do: {:error, :invalid_limit}

  @doc "Reads a bounded slice of durable evidence, including clean audits."
  @spec evidence(String.t(), non_neg_integer(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def evidence(id, offset \\ 0, limit \\ 8_000)

  def evidence(id, offset, limit) when is_binary(id) and is_integer(offset) and offset >= 0 and limit in 1..32_000 do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %QAAttempt{} = row <- Repo.get(QAAttempt, uuid) do
      facts = %{
        project: row.project_name,
        revision: row.revision,
        base_sha: row.base_sha,
        command: row.command,
        agent: row.agent,
        model: row.model,
        landing_shas: row.landing_shas,
        report: row.report
      }

      text = Jason.encode!(facts) <> "\n" <> (row.transcript || "")
      {:ok, %{id: row.id, evidence: String.slice(text, offset, limit), offset: offset, total: String.length(text)}}
    else
      _ -> {:error, :not_found}
    end
  rescue
    error in @db_errors -> {:error, {:qa_unavailable, Exception.message(error)}}
  end

  def evidence(_id, _offset, _limit), do: {:error, :invalid_limit}

  @spec report_status(attempt(), term(), term()) :: String.t()
  defp report_status(attempt, qa, :exited) when is_map(qa) do
    if qa["revision"] == attempt.revision and same_command?(qa["command"], attempt.command) and
         qa["status"] in ["passed", "failed", "incomplete"] and
         nonempty?(qa["evidence"]) and nonempty?(qa["report"]) do
      qa["status"]
    else
      "incomplete"
    end
  end

  defp report_status(_attempt, _qa, _termination), do: "incomplete"

  @spec same_command?(term(), String.t()) :: boolean()
  defp same_command?(reported, configured) when is_binary(reported) do
    String.trim(reported) == String.trim(configured)
  end

  defp same_command?(_reported, _configured), do: false

  @spec nonempty?(term()) :: boolean()
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  @spec summary(attempt()) :: map()
  defp summary(row) do
    status = observed_status(row)

    row
    |> Map.from_struct()
    |> Map.take([
      :id,
      :project_name,
      :target_branch,
      :base_sha,
      :revision,
      :command,
      :agent,
      :model,
      :job_id,
      :attempt,
      :inserted_at,
      :updated_at
    ])
    |> Map.merge(%{status: status, included_landings: length(row.landing_shas)})
  end

  @spec observed_status(attempt()) :: String.t()
  defp observed_status(%{status: "running", job_id: job_id}) when not is_nil(job_id) do
    case Repo.get(Oban.Job, job_id) do
      %{state: "executing"} -> "running"
      _ -> "incomplete"
    end
  end

  defp observed_status(row), do: row.status
end
