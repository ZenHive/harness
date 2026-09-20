defmodule Harness.Repo.Migrations.CreateRunInsights do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:run_insights_documents, primary_key: false) do
      add :id, :text, primary_key: true
      add :kind, :text, null: false
      add :data, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:run_insights_documents, [:kind, :updated_at, :id])
  end
end
