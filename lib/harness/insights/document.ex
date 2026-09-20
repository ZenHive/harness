defmodule Harness.Insights.Document do
  @moduledoc false
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "run_insights_documents" do
    field :kind, :string
    field :data, :map
    timestamps(type: :utc_datetime_usec)
  end
end
