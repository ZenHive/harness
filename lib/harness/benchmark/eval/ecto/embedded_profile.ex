defmodule Harness.Benchmark.Eval.Ecto.EmbeddedProfile do
  @moduledoc "Benchmark reference: embedded profile changeset validation."
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          name: String.t() | nil,
          age: integer() | nil
        }

  @primary_key false
  embedded_schema do
    field :name, :string
    field :age, :integer
  end

  @doc false
  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :age])
    |> validate_required([:name, :age])
    |> validate_number(:age, greater_than: 0, less_than_or_equal_to: 150)
  end
end
