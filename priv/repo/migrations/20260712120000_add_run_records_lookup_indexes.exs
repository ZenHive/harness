defmodule Harness.Repo.Migrations.AddRunRecordsLookupIndexes do
  @moduledoc false
  use Ecto.Migration

  # Columns filtered/grouped by the result-store query paths but previously unindexed:
  # - task_id: recovery/idempotency lookup (Run.Worker.recoverable_run_record/2)
  # - landed_sha: post-merge cold-check persist (Audit.persist_cold_check/4)
  # - verdict: apply_filters/2 :verdict clause + every approve-rate aggregate predicate
  # - reviewer_adapter: aggregate_reviewer_reliability WHERE not is_nil + GROUP BY
  def change do
    create index(:run_records, [:task_id])
    create index(:run_records, [:landed_sha])
    create index(:run_records, [:verdict])
    create index(:run_records, [:reviewer_adapter])
  end
end
