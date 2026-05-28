defmodule Harness.Chat.StreamTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Stream

  test "topic/1 and subscribe/broadcast deliver events" do
    session_id = "chat-#{System.unique_integer([:positive])}"
    assert Stream.topic(session_id) == "harness:chat:" <> session_id <> ":stream"

    assert :ok = Stream.subscribe(session_id)
    event = %{type: "text_delta", text: "hi"}
    assert :ok = Stream.broadcast(session_id, event)

    assert_receive {:harness_chat_stream, ^session_id, ^event}, 500

    assert :ok = Stream.unsubscribe(session_id)
    assert :ok = Stream.broadcast(session_id, %{type: "text_delta", text: "later"})
    refute_receive {:harness_chat_stream, ^session_id, _}, 100
  end
end
