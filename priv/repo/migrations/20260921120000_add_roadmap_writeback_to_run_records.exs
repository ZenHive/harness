defmodule Harness.Repo.Migrations.AddRoadmapWritebackToRunRecords do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :roadmap_writeback, :map
    end
  end
end
