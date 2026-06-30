defmodule Harness.Repo.Migrations.AddDepFreshnessSnapshots do
  use Ecto.Migration

  def change do
    create table(:dep_freshness_snapshots, primary_key: false) do
      add :project_name, :string, primary_key: true
      add :language, :string, null: false
      add :checked_at, :utc_datetime_usec, null: false
      add :outdated_count, :integer, null: false, default: 0
      add :rows, {:array, :map}, null: false, default: []

      timestamps()
    end
  end
end
