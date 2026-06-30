defmodule Harness.Repo.Migrations.AddConformanceToDepFreshnessSnapshots do
  use Ecto.Migration

  def change do
    alter table(:dep_freshness_snapshots) do
      add :conformance, :map
    end
  end
end
