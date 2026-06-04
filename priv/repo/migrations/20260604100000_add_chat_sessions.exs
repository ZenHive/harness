defmodule Harness.Repo.Migrations.AddChatSessions do
  @moduledoc false
  use Ecto.Migration

  def change do
    create_if_not_exists table(:chat_sessions, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :messages, {:array, :map}, null: false

      timestamps(type: :naive_datetime_usec)
    end
  end
end
