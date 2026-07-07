defmodule Harness.Repo.Migrations.AddSuiteHealthResults do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:suite_health_results, primary_key: false) do
      add :project_name, :string, primary_key: true
      add :checked_at, :utc_datetime_usec, null: false
      add :passed, :boolean
      add :exit_code, :integer
      add :command, :string
      add :base_sha, :string
      add :skip_reason, :string
      add :failing_tests, {:array, :map}, null: false, default: []
      add :languages, :string, null: false, default: ""

      timestamps()
    end
  end
end
