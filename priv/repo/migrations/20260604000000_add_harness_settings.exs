defmodule Harness.Repo.Migrations.AddHarnessSettings do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:harness_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :payload, :binary, null: false

      timestamps()
    end
  end

  def down do
    drop table(:harness_settings)
  end
end
