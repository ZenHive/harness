defmodule Harness.ResultStore.Schema.CapabilityScore do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "capability_scores" do
    field :agent, :string, primary_key: true
    field :domain, :string, primary_key: true
    field :corpus_version, :string, primary_key: true
    field :scored_at, :utc_datetime_usec
    field :composite_score, :float
    field :payload, :binary

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    cast(struct, attrs, [:agent, :domain, :corpus_version, :scored_at, :composite_score, :payload])
  end

  @type t :: %__MODULE__{}
end
