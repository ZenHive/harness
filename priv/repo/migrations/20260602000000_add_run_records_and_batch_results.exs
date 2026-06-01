defmodule Harness.Repo.Migrations.AddRunRecordsAndBatchResults do
  use Ecto.Migration

  def up do
    create table(:run_records, primary_key: false) do
      add :run_id, :string, primary_key: true
      add :batch_id, :string
      add :task_id, :string
      add :project_name, :string
      add :agent, :string
      add :model, :string
      add :adapter, :string
      add :state, :string
      add :verdict, :string
      add :agent_outcome_kind, :string
      add :duration_ms, :integer
      add :repair_attempts, :integer
      add :first_attempt_failed_check_count, :integer
      add :agent_diff_size, :integer
      add :agent_exit_status, :integer

      add :reason, :map
      add :token_usage, :map
      add :composed_inputs, :map
      add :failure_cause, :map
      add :check_output, :map
      add :domains, :map

      add :agent_output, :binary

      timestamps()
    end

    create table(:batch_results, primary_key: false) do
      add :batch_id, :string, primary_key: true
      add :total, :integer
      add :max_concurrency, :integer
      add :payload, :binary

      timestamps()
    end

    create index(:run_records, [:batch_id])
    create index(:run_records, [:agent])
    create index(:run_records, [:project_name])
    create index(:run_records, [:inserted_at])
  end

  def down do
    drop table(:batch_results)
    drop table(:run_records)
  end
end
