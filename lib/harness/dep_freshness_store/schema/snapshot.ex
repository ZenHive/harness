defmodule Harness.DepFreshnessStore.Schema.Snapshot do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:project_name, :string, autogenerate: false}
  schema "dep_freshness_snapshots" do
    field :language, :string
    field :checked_at, :utc_datetime_usec
    field :outdated_count, :integer
    field :rows, {:array, :map}, default: []
    field :conformance, :map

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = snapshot, attrs) do
    snapshot
    |> cast(attrs, [:project_name, :language, :checked_at, :outdated_count, :rows, :conformance])
    |> validate_required([:project_name, :language, :checked_at, :outdated_count, :rows])
  end

  @type t :: %__MODULE__{}
end
