defmodule Harness.ResultStore.Schema.BatchResult do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:batch_id, :string, autogenerate: false}
  schema "batch_results" do
    field :total, :integer
    field :max_concurrency, :integer
    field :payload, :binary

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    cast(struct, attrs, [:batch_id, :total, :max_concurrency, :payload])
  end

  @type t :: %__MODULE__{}
end
