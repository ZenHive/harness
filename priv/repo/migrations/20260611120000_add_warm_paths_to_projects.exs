defmodule Harness.Repo.Migrations.AddWarmPathsToProjects do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :warm_paths, {:array, :string}, null: false, default: []
    end
  end
end
