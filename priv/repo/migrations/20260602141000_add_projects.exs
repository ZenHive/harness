defmodule Harness.Repo.Migrations.AddProjects do
  use Ecto.Migration

  def up do
    create table(:projects, primary_key: false) do
      add :name, :string, primary_key: true
      add :payload, :binary

      timestamps()
    end
  end

  def down do
    drop table(:projects)
  end
end
