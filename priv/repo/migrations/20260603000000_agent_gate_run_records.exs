defmodule Harness.Repo.Migrations.AgentGateRunRecords do
  @moduledoc false
  use Ecto.Migration

  # Agent-gate workflow rebuild (2026-06-03): the reviewer AI is the gate, so
  # run records persist its verdict artifact (report + ratings + own-diff size)
  # and drop every column the deleted mechanical verification stack wrote
  # (check counts, check output, failure causes, stuck reports, repair attempts).
  def up do
    alter table(:run_records) do
      remove :repair_attempts
      remove :first_attempt_failed_check_count
      remove :reviewer_stuck_report
      remove :failure_cause
      remove :check_output

      add :reviewer_diff_size, :integer
      add :review_report, :binary
      add :review_ratings, :map
    end
  end

  def down do
    alter table(:run_records) do
      remove :reviewer_diff_size
      remove :review_report
      remove :review_ratings

      add :repair_attempts, :integer
      add :first_attempt_failed_check_count, :integer
      add :reviewer_stuck_report, :binary
      add :failure_cause, :map
      add :check_output, :map
    end
  end
end
