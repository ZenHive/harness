defmodule Harness.Repo.Migrations.AddReviewerFallbackCountsToRunRecords do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :reviewer_reprompt_count, :integer, default: 0, null: false
      add :reviewer_rotation_count, :integer, default: 0, null: false
    end
  end
end
