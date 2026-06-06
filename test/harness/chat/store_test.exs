defmodule Harness.Chat.StoreTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Store
  # Each test gets an isolated tmp root via @tag :tmp_dir, passed as `root:` so
  # the config'd shared test root never leaks state between tests.
  alias Harness.Chat.Store.Memory

  @moduletag :tmp_dir

  describe "save/3 + load/2 round-trip" do
    test "persists messages and reloads them", %{tmp_dir: dir} do
      messages = [
        %{role: :user, content: "hello"},
        %{role: :assistant, content: [%{type: "text", text: "hi"}]}
      ]

      assert :ok = Store.save("chat-abc", messages, root: dir)
      assert {:ok, record} = Store.load("chat-abc", root: dir)
      assert record.session_id == "chat-abc"
      assert record.messages == messages
      assert %DateTime{} = record.updated_at
    end

    test "load of an unknown session is :not_found", %{tmp_dir: dir} do
      assert {:error, :not_found} = Store.load("chat-missing", root: dir)
    end

    test "save overwrites the prior record for the same id", %{tmp_dir: dir} do
      :ok = Store.save("chat-x", [%{role: :user, content: "first"}], root: dir)
      :ok = Store.save("chat-x", [%{role: :user, content: "second"}], root: dir)

      assert {:ok, %{messages: [%{content: "second"}]}} = Store.load("chat-x", root: dir)
    end

    test "bounds persisted history to the most recent 200 messages", %{tmp_dir: dir} do
      messages = for i <- 1..250, do: %{role: :user, content: "m#{i}"}
      :ok = Store.save("chat-big", messages, root: dir)

      {:ok, %{messages: loaded}} = Store.load("chat-big", root: dir)
      assert length(loaded) == 200
      # The tail is kept (oldest dropped).
      assert List.first(loaded) == %{role: :user, content: "m51"}
      assert List.last(loaded) == %{role: :user, content: "m250"}
    end
  end

  describe "list/1" do
    test "summarizes persisted sessions, most-recent first", %{tmp_dir: dir} do
      :ok = Store.save("chat-1", [%{role: :user, content: "alpha task"}], root: dir)
      :ok = Store.save("chat-2", [%{role: :user, content: "beta task"}, %{role: :assistant, content: []}], root: dir)

      summaries = Store.list(root: dir)
      assert length(summaries) == 2
      ids = Enum.map(summaries, & &1.session_id)
      assert "chat-1" in ids
      assert "chat-2" in ids

      two = Enum.find(summaries, &(&1.session_id == "chat-2"))
      assert two.label == "beta task"
      assert two.message_count == 2
      assert %DateTime{} = two.updated_at
    end

    test "is empty when nothing is persisted", %{tmp_dir: dir} do
      assert Store.list(root: dir) == []
    end
  end

  describe "derive_label/1" do
    test "uses the first user message text, truncated" do
      long = String.duplicate("x", 80)
      assert Store.derive_label([%{role: :user, content: long}]) == String.slice(long, 0, 60) <> "…"
    end

    test "falls back to a default when there is no user text" do
      assert Store.derive_label([]) == "New chat"
      assert Store.derive_label([%{role: :assistant, content: [%{type: "text", text: "hi"}]}]) == "New chat"
    end

    test "reads a string-keyed user message (post-JSON shape)" do
      assert Store.derive_label([%{"role" => "user", "content" => "hi there"}]) == "hi there"
    end

    test "treats a whitespace-only user message as no text" do
      assert Store.derive_label([%{role: :user, content: "   \n\t "}]) == "New chat"
    end
  end

  describe "backend selection (facade dispatch)" do
    setup do
      prior_backend = Application.get_env(:harness, :chat_store_backend)
      prior_repo_enabled = Application.get_env(:harness, :repo_enabled)

      on_exit(fn ->
        restore(:chat_store_backend, prior_backend)
        restore(:repo_enabled, prior_repo_enabled)
      end)

      :ok
    end

    test "defaults to the memory backend when repo is disabled and unconfigured" do
      Application.put_env(:harness, :repo_enabled, false)
      Application.delete_env(:harness, :chat_store_backend)
      assert Store.configured() == Memory
    end

    test "a {module, opts} backend merges its opts under call-time opts", %{tmp_dir: dir} do
      # Backend opts supply the root; no call-time root is passed.
      Application.put_env(:harness, :chat_store_backend, {Memory, [root: dir]})

      assert :ok = Store.save("chat-tuple", [%{role: :user, content: "via backend opts"}])
      assert {:ok, %{messages: [%{content: "via backend opts"}]}} = Store.load("chat-tuple")
    end

    test "call-time opts override the backend's configured opts", %{tmp_dir: dir} do
      # Backend root is bogus; the call-time root: dir must win (Keyword.merge).
      Application.put_env(
        :harness,
        :chat_store_backend,
        {Memory, [root: "/nonexistent/should/be/overridden"]}
      )

      assert :ok = Store.save("chat-override", [%{role: :user, content: "wins"}], root: dir)
      assert {:ok, %{messages: [%{content: "wins"}]}} = Store.load("chat-override", root: dir)
    end
  end

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
