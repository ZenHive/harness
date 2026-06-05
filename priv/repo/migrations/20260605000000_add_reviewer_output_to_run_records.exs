defmodule Harness.Repo.Migrations.AddReviewerOutputToRunRecords do
  @moduledoc false
  use Ecto.Migration

  # Task 232: persist the reviewer agent's raw transcript + settled outcome
  # facts on Harness.Run.LogRecord, mirroring the implementer's agent_output /
  # agent_outcome_kind / agent_exit_status. Lets a :review_stuck run (reviewer
  # exited without writing the verdict file) be diagnosed after the fact.
  def change do
    alter table(:run_records) do
      add :reviewer_outcome_kind, :string
      add :reviewer_exit_status, :integer
      add :reviewer_output, :binary
    end
  end
end
