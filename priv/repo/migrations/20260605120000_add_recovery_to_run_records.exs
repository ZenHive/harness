defmodule Harness.Repo.Migrations.AddRecoveryToRunRecords do
  @moduledoc false
  use Ecto.Migration

  # Task 229 (v0_14, AR-seam): persist the bounded AI-recovery witness on
  # Harness.Run.LogRecord as raw facts — attempt count, the last decision, the
  # repair note, and the recovery token spend. No scoring; the token figure is
  # the metric that proves two-tier recovery beats hard-fail + manual redispatch.
  #
  # Migration-ordering: this is a purely additive `alter table ... add` and is
  # order-independent w.r.t. Task 224's `review_skills` column add on the same
  # table. Timestamp 20260605120000 is sequenced AFTER Task 232's reviewer-output
  # migration (20260605000000); Task 224's migration carries its own distinct
  # timestamp, so the two never collide.
  def change do
    alter table(:run_records) do
      add :recovery_attempts, :integer
      add :recovery_outcome, :string
      add :recovery_repaired, :binary
      add :recovery_token_usage, :map
    end
  end
end
