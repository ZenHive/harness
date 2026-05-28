defmodule Harness.Chat.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Claude.StreamParser

  describe "feed/2" do
    test "emits nothing while the buffer holds a partial line" do
      {events, parser} = StreamParser.feed(StreamParser.new(), ~s({"type":"system",))
      assert events == []
      assert parser.buffer == ~s({"type":"system",)
    end

    test "emits one event per fully-terminated JSON line" do
      input =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
        }) <> "\n"

      {events, parser} = StreamParser.feed(StreamParser.new(), input)
      assert events == [{:assistant_text, "hi"}]
      assert parser.buffer == ""
    end

    test "fans out multiple content blocks within one assistant message" do
      input =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "Let me check..."},
              %{"type" => "tool_use", "id" => "toolu_1", "name" => "x__y", "input" => %{"k" => 1}},
              %{"type" => "text", "text" => " and then"}
            ]
          }
        }) <> "\n"

      {events, _parser} = StreamParser.feed(StreamParser.new(), input)

      assert events == [
               {:assistant_text, "Let me check..."},
               {:assistant_tool_use, %{id: "toolu_1", name: "x__y", input: %{"k" => 1}}},
               {:assistant_text, " and then"}
             ]
    end

    test "stitches chunks split mid-line across calls" do
      payload =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "complete"}]}
        }) <> "\n"

      {head, tail} = String.split_at(payload, 30)

      {events_1, parser_1} = StreamParser.feed(StreamParser.new(), head)
      assert events_1 == []
      assert parser_1.buffer == head

      {events_2, parser_2} = StreamParser.feed(parser_1, tail)
      assert events_2 == [{:assistant_text, "complete"}]
      assert parser_2.buffer == ""
    end

    test "emits one event per terminated line when several arrive in one chunk" do
      line_1 = Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "s1"})

      line_2 =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "hello"}]}
        })

      chunk = line_1 <> "\n" <> line_2 <> "\n"

      {events, parser} = StreamParser.feed(StreamParser.new(), chunk)
      assert [{:system_init, _}, {:assistant_text, "hello"}] = events
      assert parser.buffer == ""
    end

    test "translates user tool_result blocks (claude's own internal loop)" do
      input =
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "[]"}
            ]
          }
        }) <> "\n"

      {events, _parser} = StreamParser.feed(StreamParser.new(), input)
      assert events == [{:tool_result, %{tool_use_id: "toolu_1", content: "[]"}}]
    end

    test "tags the terminal result event" do
      input =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "stop_reason" => "end_turn",
          "session_id" => "sess-1"
        }) <> "\n"

      {events, _parser} = StreamParser.feed(StreamParser.new(), input)
      assert [{:result, %{"stop_reason" => "end_turn", "session_id" => "sess-1"}}] = events
    end

    test "drops non-JSON lines silently (banner/blank stderr noise)" do
      chunk = "claude version 1.2.3\n\n" <> Jason.encode!(%{"type" => "result"}) <> "\n"

      {events, _parser} = StreamParser.feed(StreamParser.new(), chunk)
      assert [{:result, %{"type" => "result"}}] = events
    end

    test "tags unknown top-level types via :unknown" do
      input = Jason.encode!(%{"type" => "telemetry", "data" => "x"}) <> "\n"

      {events, _parser} = StreamParser.feed(StreamParser.new(), input)
      assert [{:unknown, %{"type" => "telemetry", "data" => "x"}}] = events
    end
  end

  describe "finalize/1" do
    test "is a no-op on an empty buffer" do
      assert {[], %StreamParser{buffer: ""}} = StreamParser.finalize(StreamParser.new())
    end

    test "parses a complete JSON object even when no trailing newline arrives" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "end-of-stream"}]}
        })

      {[], parser} = StreamParser.feed(StreamParser.new(), line)
      assert parser.buffer == line

      {events, parser} = StreamParser.finalize(parser)
      assert events == [{:assistant_text, "end-of-stream"}]
      assert parser.buffer == ""
    end

    test "drops a partial-JSON fragment quietly" do
      {[], parser} = StreamParser.feed(StreamParser.new(), ~s({"type":"assistant",))
      {events, parser} = StreamParser.finalize(parser)
      assert events == []
      assert parser.buffer == ""
    end
  end
end
