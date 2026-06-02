defmodule Harness.Repo.Migrations.AddReviewerFieldsToRunRecords do
  @moduledoc false
  use Ecto.Migration

  # Task 163 (reviewer-pair deletion pass): persist the reviewer-pair outcome
  # fields Task 161 added to Harness.Run.LogRecord. The legacy repair_attempts
  # column is deliberately left in place (no longer written or read) so existing
  # rows keep their history without a destructive migration.
  def change do
    alter table(:run_records) do
      add :review_iterations, :integer
      add :reviewer_adapter, :string
      add :reviewer_stuck_report, :binary
    end
  end
end
