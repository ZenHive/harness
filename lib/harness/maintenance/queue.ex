defmodule Harness.Maintenance.Queue do
  @moduledoc "Atomic trigger deduplication and queued progress, independent of Oban testing modes."
  import Ecto.Query

  alias Harness.Maintenance.Recovery
  alias Harness.Maintenance.Store
  alias Harness.Maintenance.Worker
  alias Harness.Repo

  @doc "Queues one repository under a database lock without racing progress against worker startup."
  @spec enqueue(String.t()) :: {:ok, integer()} | {:error, term()}
  def enqueue(project) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(444, $1)", [:erlang.phash2(project)])

        query =
          from job in Oban.Job,
            where:
              job.worker == "Harness.Maintenance.Worker" and
                job.state in ["available", "scheduled", "executing", "retryable"] and
                fragment("?->>'project' = ?", job.args, ^project),
            limit: 1

        case Repo.one(query) do
          nil -> insert(project)
          job -> job.id
        end
      end)

    case result do
      {:ok, _} = ok ->
        Phoenix.PubSub.broadcast(Harness.PubSub, "harness:maintenance", :maintenance_updated)
        ok

      other ->
        other
    end
  end

  @spec insert(String.t()) :: integer()
  defp insert(project) do
    pass_id = Recovery.pass_id(project)

    case Harness.Oban.insert(Worker.new(%{"project" => project, "pass_id" => pass_id})) do
      {:ok, %{id: id}} when is_integer(id) ->
        progress = %{"state" => "queued", "at" => DateTime.to_iso8601(DateTime.utc_now()), "id" => pass_id}
        :ok = Store.put_many([{"progress/" <> project, "progress", progress}])
        id

      {:error, reason} ->
        Repo.rollback(reason)

      _ ->
        Repo.rollback(:enqueue_conflict)
    end
  end
end
