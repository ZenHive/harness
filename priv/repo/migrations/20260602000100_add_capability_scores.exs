defmodule Harness.Repo.Migrations.AddCapabilityScores do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:capability_scores, primary_key: false) do
      add :agent, :string, primary_key: true
      add :domain, :string, primary_key: true
      add :corpus_version, :string, primary_key: true
      add :scored_at, :utc_datetime_usec
      add :composite_score, :float
      add :payload, :binary

      timestamps()
    end

    create index(:capability_scores, [:domain])
    create index(:capability_scores, [:scored_at])
  end
end
