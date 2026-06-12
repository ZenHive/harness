defmodule Harness.Chat.Store.PostgresTest do
  # async: false because DataCase uses SQL Sandbox shared mode for DB-backed collaborators.
  use Harness.DataCase, async: false

  alias Harness.Chat.Store
  alias Harness.Chat.Store.Postgres, as: PostgresStore

  @moduletag :integration

  describe "save/3 + load/2 round-trip" do
    test "persists messages and reloads with atom keys + role restored" do
      messages = [
        %{role: :user, content: "hello"},
        %{role: :assistant, content: [%{type: "text", text: "hi"}]}
      ]

      assert :ok = PostgresStore.save("chat-pg", messages, [])
      assert {:ok, record} = PostgresStore.load("chat-pg", [])
      assert record.session_id == "chat-pg"
      assert %DateTime{} = record.updated_at

      assert [%{role: :user, content: "hello"}, %{role: :assistant, content: content}] =
               record.messages

      assert [%{type: "text", text: "hi"}] = content
    end

    test "save overwrites the prior record for the same id (upsert)" do
      :ok = PostgresStore.save("chat-up", [%{role: :user, content: "first"}], [])
      :ok = PostgresStore.save("chat-up", [%{role: :user, content: "second"}], [])

      assert {:ok, %{messages: [%{role: :user, content: "second"}]}} =
               PostgresStore.load("chat-up", [])
    end

    test "caps persisted messages at the most recent 200" do
      messages = for i <- 1..250, do: %{role: :user, content: "m#{i}"}
      :ok = PostgresStore.save("chat-cap", messages, [])

      assert {:ok, %{messages: loaded}} = PostgresStore.load("chat-cap", [])
      assert length(loaded) == 200
      assert List.last(loaded) == %{role: :user, content: "m250"}
      assert hd(loaded) == %{role: :user, content: "m51"}
    end

    test "load of an unknown session is :not_found" do
      assert {:error, :not_found} = PostgresStore.load("chat-missing", [])
    end
  end

  describe "list/1" do
    test "returns summaries, most-recently-updated first" do
      :ok = PostgresStore.save("chat-a", [%{role: :user, content: "alpha question"}], [])
      :ok = PostgresStore.save("chat-b", [%{role: :user, content: "beta question"}], [])

      summaries = PostgresStore.list([])
      ids = Enum.map(summaries, & &1.session_id)
      assert "chat-a" in ids and "chat-b" in ids

      a = Enum.find(summaries, &(&1.session_id == "chat-a"))
      assert a.label == "alpha question"
      assert a.message_count == 1
      assert %DateTime{} = a.updated_at
    end

    test "is empty when nothing is persisted" do
      assert PostgresStore.list([]) == []
    end
  end

  describe "repo_enabled selection" do
    test "repo_enabled true selects Postgres and sessions reload through a fresh facade lookup" do
      prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
      prior_chat_backend = Application.get_env(:harness, :chat_store_backend)

      Application.put_env(:harness, :repo_enabled, true)
      Application.delete_env(:harness, :chat_store_backend)

      on_exit(fn ->
        restore(:repo_enabled, prior_repo_enabled)
        restore(:chat_store_backend, prior_chat_backend)
      end)

      assert Store.configured() == PostgresStore
      assert :ok = PostgresStore.save("chat-pg-survives", [%{role: :user, content: "still here"}], repo: Repo)

      assert {:ok, %{messages: [%{role: :user, content: "still here"}]}} =
               PostgresStore.load("chat-pg-survives", repo: Repo)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
