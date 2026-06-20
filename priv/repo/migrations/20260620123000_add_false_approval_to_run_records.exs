defmodule Harness.Repo.Migrations.AddFalseApprovalToRunRecords do
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :reviewer_model, :string
      add :approved_then_found_red, :map
    end
  end
end
