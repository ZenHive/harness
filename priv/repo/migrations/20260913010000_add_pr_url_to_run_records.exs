defmodule Harness.Repo.Migrations.AddPrUrlToRunRecords do
  @moduledoc """
  Persist the `:pr` landing artifact URL and writeback state on each run record.

  `pr_url` is nil until a pull request is opened. `pr_writeback` records that the
  open/merged/closed writeback already ran so the PR poller is idempotent.
  Historical rows stay nil and read as having no PR.
  """

  use Ecto.Migration

  def change do
    alter table(:run_records) do
      add :pr_url, :string
      add :pr_writeback, :string
    end
  end
end
