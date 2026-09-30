defmodule Harness.Repo.Migrations.AddRunReviewEvidence do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :review_evidence, :map, default: %{}, null: false
    end
  end
end
