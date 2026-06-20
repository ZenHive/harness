defmodule Harness.Repo.Migrations.AddReviewChecksAndConcernsToRunRecords do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :review_checks, :map
      add :review_concerns, :map
      add :review_warning, :boolean, default: false, null: false
    end
  end
end
