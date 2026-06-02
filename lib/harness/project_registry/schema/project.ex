defmodule Harness.ProjectRegistry.Schema.Project do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:name, :string, autogenerate: false}
  schema "projects" do
    field :payload, :binary

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    cast(struct, attrs, [:name, :payload])
  end

  @type t :: %__MODULE__{}
end
