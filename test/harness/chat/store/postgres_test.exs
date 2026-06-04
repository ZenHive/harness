defmodule Harness.Chat.Store.PostgresTest do
  use Harness.DataCase, async: false

  alias Harness.Chat.Store
  alias Harness.Chat.Store.Postgres, as: PostgresStore

  @moduletag :integration

  setup do
    prior = Application.get_env(:harness, :chat_store_backend)
    Application.put_env(:harness, :chat_store_backend, PostgresStore)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:harness, :chat_store_backend, prior),
        else: Application.delete_env(:harness, :chat_store_backend)
    end)

    :ok
  end

  test "save/3 + load/2 round-trip through the Store facade" do
    messages = [%{role: :user, content: "postgres probe"}]

    assert :ok = Store.save("chat-pg-1", messages)
    assert {:ok, record} = Store.load("chat-pg-1")
    assert record.session_id == "chat-pg-1"
    assert record.messages == messages
    assert %DateTime{} = record.updated_at

    summaries = Store.list()
    assert Enum.any?(summaries, &(&1.session_id == "chat-pg-1"))
  end
end
