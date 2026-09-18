defmodule Harness.Repo.Migrations.AddDispatchDecisionToRunRecords do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :dispatch_decision, :map, default: %{}, null: false
      add :task_ids, {:array, :string}, default: [], null: false
    end
  end
end
