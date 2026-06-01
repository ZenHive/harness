defmodule Harness.Repo.Migrations.RunRecordsUsecTimestamps do
  @moduledoc """
  Second-precision timestamps() made `ORDER BY inserted_at DESC` (Task 139's
  recency ordering) non-deterministic for records inserted within the same
  second — the run_records PK is a string run_id, so there is no serial column
  to tiebreak on. Microsecond precision makes inserted_at a real recency key.
  """

  use Ecto.Migration

  def change do
    alter table(:run_records) do
      modify :inserted_at, :naive_datetime_usec, from: :naive_datetime
      modify :updated_at, :naive_datetime_usec, from: :naive_datetime
    end
  end
end
