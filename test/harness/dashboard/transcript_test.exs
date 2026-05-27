defmodule Harness.Dashboard.TranscriptTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.Transcript

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
end
