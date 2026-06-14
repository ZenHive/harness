defmodule Harness.Repo.Migrations.AddTaskFingerprintToRunRecords do
  @moduledoc """
  Store the dispatch-time roadmap task fingerprint for safe lander writeback.

  Historical rows remain NULL and therefore re-land without the drift guard; new
  runs carry the fingerprint from `Harness.Roadmap.ingest/2`.
  """

  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :task_fingerprint, :string
    end
  end
end
