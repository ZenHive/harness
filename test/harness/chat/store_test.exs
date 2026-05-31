defmodule Harness.Chat.StoreTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Store

  # Each test gets an isolated tmp root via @tag :tmp_dir, passed as `root:` so
  # the config'd shared test root never leaks state between tests.
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

    test "skips undecodable term files instead of crashing", %{tmp_dir: dir} do
      :ok = Store.save("chat-ok", [%{role: :user, content: "good"}], root: dir)
      File.write!(Path.join(dir, "garbage.term"), "not an erlang term")

      summaries = Store.list(root: dir)
      assert [%{session_id: "chat-ok"}] = summaries
    end

    # Mirrors the ResultStore.File drift fix: read_term/1 decodes WITHOUT [:safe],
    # so a session whose message references an atom not interned in the running
    # BEAM (written by a prior build) still loads instead of being dropped.
    test "loads a session whose atom is absent from the table (would fail under :safe)", %{tmp_dir: dir} do
      :ok = Store.save("chat-drift", [%{role: :user, content: "hi", marker: :drift_chat_placeholder}], root: dir)

      # session_path/2 base64url-encodes the id (no padding) + ".term".
      path = Path.join(dir, Base.url_encode64("chat-drift", padding: false) <> ".term")
      bin = File.read!(path)
      name = Atom.to_string(:drift_chat_placeholder)
      # Fresh, never-interned, same-length atom name (see file_test for rationale).
      novel =
        ("z" <> Integer.to_string(System.unique_integer([:positive])))
        |> String.pad_trailing(byte_size(name), "z")
        |> binary_part(0, byte_size(name))

      assert byte_size(novel) == byte_size(name)
      assert length(:binary.matches(bin, name)) == 1

      patched = :binary.replace(bin, name, novel)
      assert_raise ArgumentError, fn -> :erlang.binary_to_term(patched, [:safe]) end
      File.write!(path, patched)

      assert {:ok, record} = Store.load("chat-drift", root: dir)
      assert [%{marker: marker}] = record.messages
      assert marker == String.to_atom(novel)
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
  end

  describe "disabled store" do
    test "save is a no-op, load is :not_found, list is empty" do
      assert :ok = Store.save("chat-disabled", [%{role: :user, content: "x"}], root: false)
      assert {:error, :not_found} = Store.load("chat-disabled", root: false)
      assert [] = Store.list(root: false)
    end
  end
end
