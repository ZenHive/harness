defmodule Harness.ResultStore.Schema.BatchResult do
  @moduledoc """
  Ecto schema for the batch_results table (Task 137). Payload is the full
  %Harness.Batch.Result{} as term_to_binary for whole-struct load_batch/2.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:batch_id, :string, autogenerate: false}
  schema "batch_results" do
    field :total, :integer
    field :max_concurrency, :integer
    field :payload, :binary

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    cast(struct, attrs, [:batch_id, :total, :max_concurrency, :payload])
  end

  @type t :: %__MODULE__{}
end
