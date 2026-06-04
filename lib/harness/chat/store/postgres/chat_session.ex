defmodule Harness.Chat.Store.Postgres.ChatSession do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:session_id, :string, autogenerate: false}
  schema "chat_sessions" do
    field :messages, {:array, :map}

    timestamps(type: :naive_datetime_usec)
  end

  @doc """
  Builds a changeset for a chat session.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    struct
    |> cast(attrs, [:session_id, :messages])
    |> validate_required([:session_id, :messages])
  end

  @type t :: %__MODULE__{}
end
