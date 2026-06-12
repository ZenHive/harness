defmodule Harness.Repo.Migrations.AddLandedShaToRunRecords do
  @moduledoc """
  Persist the lander's pushed SHA on each run record.

  Backfill decision: no one-shot rmap/git backfill. Rows written before this
  column existed keep `landed_sha = NULL` and therefore read as unmerged until
  re-landed; all readers treat NULL as a normal unlanded value.
  """

  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :landed_sha, :string
    end
  end
end
