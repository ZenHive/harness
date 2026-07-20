defmodule Harness.Repo.Migrations.AddReviewProposedTasksToRunRecords do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :review_proposed_tasks, :map
    end
  end
end
