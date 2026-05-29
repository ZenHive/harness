defmodule Harness.Dashboard.TranscriptTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser

  test "topic/1 returns a stable per-run identifier" do
    assert Transcript.topic("run-abc") == "harness:run:run-abc:transcript"
    assert Transcript.topic("run-abc") == Transcript.topic("run-abc")
    refute Transcript.topic("run-a") == Transcript.topic("run-b")
  end

  test "subscribe/1 + broadcast/3 delivers seq-tagged chunks to the subscriber" do
    run_id = "run-#{System.unique_integer([:positive])}"
    assert :ok = Transcript.subscribe(run_id)

    assert :ok = Transcript.broadcast(run_id, 1, "first chunk")
    assert_receive {:harness_transcript, ^run_id, 1, "first chunk"}, 500

    assert :ok = Transcript.broadcast(run_id, 2, "second chunk")
    assert_receive {:harness_transcript, ^run_id, 2, "second chunk"}, 500
  end

  test "broadcast/3 passes iodata through untouched" do
    run_id = "run-#{System.unique_integer([:positive])}"
    :ok = Transcript.subscribe(run_id)

    iodata = ["one", [" ", "two"], " three"]
    assert :ok = Transcript.broadcast(run_id, 7, iodata)

    assert_receive {:harness_transcript, ^run_id, 7, payload}, 500
    assert IO.iodata_to_binary(payload) == "one two three"
  end

  test "unsubscribe/1 stops further deliveries" do
    run_id = "run-#{System.unique_integer([:positive])}"
    :ok = Transcript.subscribe(run_id)

    :ok = Transcript.broadcast(run_id, 1, "before")
    assert_receive {:harness_transcript, ^run_id, 1, "before"}, 500

    assert :ok = Transcript.unsubscribe(run_id)
    :ok = Transcript.broadcast(run_id, 2, "after")
    refute_receive {:harness_transcript, ^run_id, _, "after"}, 100
  end

  test "topics are isolated by run_id" do
    run_a = "run-a-#{System.unique_integer([:positive])}"
    run_b = "run-b-#{System.unique_integer([:positive])}"

    :ok = Transcript.subscribe(run_a)
    :ok = Transcript.broadcast(run_b, 1, "for b only")
    refute_receive {:harness_transcript, ^run_b, _, _}, 100
  end

  describe "append/3 (shared trim helper)" do
    test "appends to an empty buffer" do
      assert {"hello", 5} = Transcript.append(<<>>, 0, "hello")
    end

    test "appends to an existing buffer and updates byte count" do
      assert {"abc-def", 7} = Transcript.append("abc", 3, "-def")
    end

    test "accepts iodata chunks and flattens to binary" do
      assert {"one two three", 13} = Transcript.append(<<>>, 0, ["one", [" ", "two"], " three"])
    end

    test "passes the buffer through untouched when under the cap" do
      buf = String.duplicate("x", 1_024)
      assert Transcript.append(buf, 1_024, "") == {buf, 1_024}
    end

    test "trims to the configured 200 KiB tail when the buffer overflows" do
      head = String.duplicate("a", 100_000)
      tail = String.duplicate("b", 150_000)
      {trimmed, trimmed_bytes} = Transcript.append(head, 100_000, tail)

      assert trimmed_bytes == Transcript.buffer_bytes()
      assert byte_size(trimmed) == Transcript.buffer_bytes()
      # The trim keeps the most recent bytes, so the tail-most byte is unchanged
      # and the head-most byte is from the original buffer at the boundary.
      assert binary_part(trimmed, trimmed_bytes - 1, 1) == "b"
    end

    test "buffer_bytes/0 reports the trim cap" do
      assert Transcript.buffer_bytes() == 200 * 1024
    end
  end

  describe "broadcast_events/3 + topic isolation" do
    test "delivers seq-tagged event lists to the subscriber on the shared topic" do
      run_id = "run-#{System.unique_integer([:positive])}"
      :ok = Transcript.subscribe(run_id)

      events = [{:assistant_text, %{text: "hello"}}]
      assert :ok = Transcript.broadcast_events(run_id, 1, events)
      assert_receive {:harness_transcript_events, ^run_id, 1, ^events}, 500
    end

    test "shares the topic with broadcast/3 so both shapes reach one subscriber" do
      run_id = "run-#{System.unique_integer([:positive])}"
      :ok = Transcript.subscribe(run_id)

      assert :ok = Transcript.broadcast(run_id, 1, "raw bytes")
      assert :ok = Transcript.broadcast_events(run_id, 1, [{:plain_text, %{text: "rb"}}])

      assert_receive {:harness_transcript, ^run_id, 1, "raw bytes"}, 500
      assert_receive {:harness_transcript_events, ^run_id, 1, [{:plain_text, %{text: "rb"}}]}, 500
    end
  end

  describe "append_chunk/4 (parsed-event helper)" do
    test "returns {events, delta, parser_state} for a known agent_kind" do
      state = Parser.init_state(:antigravity)
      assert {events, delta, _new_state} = Transcript.append_chunk([], :antigravity, state, "hello")
      assert events == [{:plain_text, %{text: "hello"}}]
      assert delta == events
    end

    test "appends fresh events on top of an existing list" do
      state = Parser.init_state(:antigravity)
      seed = [{:plain_text, %{text: "first"}}]

      {events, delta, _new_state} = Transcript.append_chunk(seed, :antigravity, state, "second")

      assert events == seed ++ [{:plain_text, %{text: "second"}}]
      assert delta == [{:plain_text, %{text: "second"}}]
    end

    test "FIFO-evicts oldest events when the combined list exceeds event_count_cap/0" do
      Application.put_env(:harness, :dashboard, transcript_max_events: 3)
      on_exit(fn -> Application.delete_env(:harness, :dashboard) end)

      state = Parser.init_state(:antigravity)

      {events, _delta, state} = Transcript.append_chunk([], :antigravity, state, "a")
      {events, _delta, state} = Transcript.append_chunk(events, :antigravity, state, "b")
      {events, _delta, state} = Transcript.append_chunk(events, :antigravity, state, "c")
      {events, delta, _state} = Transcript.append_chunk(events, :antigravity, state, "d")

      # Cap = 3 → oldest evicted, newest preserved
      assert events == [
               {:plain_text, %{text: "b"}},
               {:plain_text, %{text: "c"}},
               {:plain_text, %{text: "d"}}
             ]

      # Delta still reports the chunk's events (cap eviction is the producer's
      # state-trim concern, not the consumer's "what just arrived" signal).
      assert delta == [{:plain_text, %{text: "d"}}]
    end

    test "empty chunk returns the input list unchanged with an empty delta" do
      state = Parser.init_state(:antigravity)
      seed = [{:plain_text, %{text: "kept"}}]

      assert {^seed, [], _new_state} = Transcript.append_chunk(seed, :antigravity, state, "")
    end
  end

  describe "finalize/3 (parsed-event helper)" do
    test "drains a buffered fragment past the parser at port close" do
      state = Parser.init_state(:claude)
      # Feed a complete JSON object WITHOUT a trailing newline — the parser
      # holds it as a fragment until finalize flushes it.
      fragment = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}})

      {events_after_append, [], state} = Transcript.append_chunk([], :claude, state, fragment)
      assert events_after_append == []

      {events, delta, _new_state} = Transcript.finalize(events_after_append, :claude, state)

      assert [{:assistant_text, %{text: "hi"}}] = events
      assert delta == events
    end

    test "empty buffer at finalize yields no events" do
      state = Parser.init_state(:claude)
      assert {[], [], _new_state} = Transcript.finalize([], :claude, state)
    end
  end

  describe "event_count_cap/0" do
    test "defaults to 500 when no config is set" do
      Application.delete_env(:harness, :dashboard)
      assert Transcript.event_count_cap() == 500
    end

    test "honors :transcript_max_events override" do
      Application.put_env(:harness, :dashboard, transcript_max_events: 42)
      on_exit(fn -> Application.delete_env(:harness, :dashboard) end)

      assert Transcript.event_count_cap() == 42
    end
  end
end
