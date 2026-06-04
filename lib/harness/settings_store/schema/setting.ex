defmodule Harness.SettingsStore.Schema.Setting do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "harness_settings" do
    field :payload, :binary

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    struct
    |> cast(attrs, [:key, :payload])
    |> validate_required([:key, :payload])
  end

  @type t :: %__MODULE__{}
end
