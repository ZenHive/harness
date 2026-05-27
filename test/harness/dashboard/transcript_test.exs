defmodule Harness.Dashboard.TranscriptTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.Transcript

  test "topic/1 returns a stable per-run identifier" do
    assert Transcript.topic("run-abc") == "harness:run:run-abc:transcript"
    assert Transcript.topic("run-abc") == Transcript.topic("run-abc")
    refute Transcript.topic("run-a") == Transcript.topic("run-b")
  end

  test "subscribe/1 + broadcast/2 delivers chunks to the subscriber" do
    run_id = "run-#{System.unique_integer([:positive])}"
    assert :ok = Transcript.subscribe(run_id)

    assert :ok = Transcript.broadcast(run_id, "first chunk")
    assert_receive {:harness_transcript, ^run_id, "first chunk"}, 500

    assert :ok = Transcript.broadcast(run_id, "second chunk")
    assert_receive {:harness_transcript, ^run_id, "second chunk"}, 500
  end

  test "broadcast/2 passes iodata through untouched" do
    run_id = "run-#{System.unique_integer([:positive])}"
    :ok = Transcript.subscribe(run_id)

    iodata = ["one", [" ", "two"], " three"]
    assert :ok = Transcript.broadcast(run_id, iodata)

    assert_receive {:harness_transcript, ^run_id, payload}, 500
    assert IO.iodata_to_binary(payload) == "one two three"
  end

  test "unsubscribe/1 stops further deliveries" do
    run_id = "run-#{System.unique_integer([:positive])}"
    :ok = Transcript.subscribe(run_id)

    :ok = Transcript.broadcast(run_id, "before")
    assert_receive {:harness_transcript, ^run_id, "before"}, 500

    assert :ok = Transcript.unsubscribe(run_id)
    :ok = Transcript.broadcast(run_id, "after")
    refute_receive {:harness_transcript, ^run_id, "after"}, 100
  end

  test "topics are isolated by run_id" do
    run_a = "run-a-#{System.unique_integer([:positive])}"
    run_b = "run-b-#{System.unique_integer([:positive])}"

    :ok = Transcript.subscribe(run_a)
    :ok = Transcript.broadcast(run_b, "for b only")
    refute_receive {:harness_transcript, ^run_b, _}, 100
  end
end
