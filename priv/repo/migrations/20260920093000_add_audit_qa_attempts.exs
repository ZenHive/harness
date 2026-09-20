defmodule Harness.Repo.Migrations.AddAuditQaAttempts do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:audit_qa_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :project_name, :text, null: false
      add :target_branch, :text
      add :base_sha, :text, null: false
      add :revision, :text
      add :command, :text, null: false
      add :status, :text, null: false
      add :agent, :text
      add :model, :text
      add :job_id, :bigint
      add :attempt, :integer
      add :landing_shas, {:array, :text}, default: [], null: false
      add :report, :map, default: %{}, null: false
      add :transcript, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:audit_qa_attempts, [:project_name, :inserted_at])
    create unique_index(:audit_qa_attempts, [:job_id, :attempt])

    create constraint(:audit_qa_attempts, :audit_qa_status,
             check: "status IN ('running', 'passed', 'failed', 'incomplete')"
           )
  end
end
