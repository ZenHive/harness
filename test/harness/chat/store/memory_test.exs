defmodule Harness.Chat.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Store
  alias Harness.Chat.Store.Memory, as: MemoryStore

  setup do
    scope = "chat-memory-#{System.unique_integer([:positive])}"
    on_exit(fn -> MemoryStore.reset(scope: scope) end)
    {:ok, opts: [scope: scope]}
  end

  test "saves, loads, and lists sessions in memory", %{opts: opts} do
    messages = [
      %{role: :user, content: "hello"},
      %{role: :assistant, content: [%{type: "text", text: "hi"}]}
    ]

    assert :ok = MemoryStore.save("chat-memory", messages, opts)
    assert {:ok, record} = MemoryStore.load("chat-memory", opts)
    assert record.session_id == "chat-memory"
    assert record.messages == messages
    assert %DateTime{} = record.updated_at

    assert [%{session_id: "chat-memory", label: "hello", message_count: 2}] = MemoryStore.list(opts)
  end

  test "ephemeral memory does not survive a reset", %{opts: opts} do
    assert :ok = MemoryStore.save("chat-reset", [%{role: :user, content: "bye"}], opts)
    assert {:ok, _record} = MemoryStore.load("chat-reset", opts)

    assert :ok = MemoryStore.reset(opts)
    assert {:error, :not_found} = MemoryStore.load("chat-reset", opts)
  end

  test "repo_enabled false selects chat memory when no explicit override" do
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_chat_backend = Application.get_env(:harness, :chat_store_backend)

    Application.put_env(:harness, :repo_enabled, false)
    Application.delete_env(:harness, :chat_store_backend)

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:chat_store_backend, prior_chat_backend)
    end)

    assert Store.configured() == MemoryStore
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
