defmodule Harness.Repo.Migrations.AddReviewSkillsToRunRecords do
  @moduledoc false
  use Ecto.Migration

  # Task 224: persist the reviewer's routing KEY (`review_facets` — open-vocabulary
  # ground-truth characterization of what the task actually was) and routing VALUE
  # (`review_skills` — two-axis domains × qualities rubric of {score, note} maps)
  # onto Harness.Run.LogRecord, alongside the legacy flat `review_ratings`. Open
  # :map (jsonb) columns — free-form keys/values, never a closed enum.
  #
  # Timestamped after the v0_13 reviewer-output migration (20260605000000) and
  # deliberately ahead of the v0_14 AR-seam recovery run_record columns so the two
  # additive alters never share a timestamp (acceptance-criteria ordering note).
  def change do
    alter table(:run_records) do
      add :review_facets, :map
      add :review_skills, :map
    end
  end
end
