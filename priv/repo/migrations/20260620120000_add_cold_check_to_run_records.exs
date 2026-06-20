defmodule Harness.Repo.Migrations.AddColdCheckToRunRecords do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :cold_check, :map
    end
  end
end
