defmodule Harness.Run.TranscriptEventsTest do
  use Harness.RunCase, async: true

  describe "transcript_events/1 (parsed event surface, Task 87)" do
    test "unknown run id resolves to :not_found" do
      assert {:error, :not_found} = Run.transcript_events("definitely-not-a-run")
    end

    @tag :capture_log
    test "an unregistered adapter degrades gracefully to agent_kind: nil + empty events" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 2_000)
      wait_until_running(run_id, 20, 2_000)

      # HangingAdapter is a test-local module not in Harness.AgentRegistry —
      # Run.init/1 resolves its agent_kind to nil so parse_chunk/2 skips
      # parsing and threads existing state untouched. The raw transcript
      # surface still works (covered above); the events surface stays empty.
      send(pid, {:transcript_chunk, "raw bytes that the parser never sees"})

      assert {:ok, %{events: [], agent_kind: nil, seq: 1}} = Run.transcript_events(run_id)
    end

    @tag :capture_log
    test "registered adapter (Antigravity) threads parser_state across chunks and broadcasts events" do
      # Antigravity IS in AgentRegistry → Run.init/1 resolves agent_kind to
      # :antigravity and initializes the Passthrough parser state. The actual
      # `agy` binary never runs because HangingAdapter is what we plug in for
      # the gen_statem's lifecycle; we use :sys.replace_state/2 to install the
      # parser surface that a real Antigravity run would have set up. This
      # exercises the actual handle_common(:transcript_chunk, ...) path through
      # the live gen_statem mailbox without spawning a real agent.
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 3_000)
      wait_until_running(run_id, 20, 3_000)

      install_agent_kind(pid, :antigravity)

      :ok = Transcript.subscribe(run_id)

      send(pid, {:transcript_chunk, "first chunk"})
      send(pid, {:transcript_chunk, "second chunk"})

      assert_receive {:harness_transcript_events, ^run_id, 1, [{:plain_text, %{text: "first chunk"}}]}, 1_000
      assert_receive {:harness_transcript_events, ^run_id, 2, [{:plain_text, %{text: "second chunk"}}]}, 1_000

      assert {:ok, %{events: events, agent_kind: :antigravity, seq: 2}} = Run.transcript_events(run_id)

      assert events == [
               {:plain_text, %{text: "first chunk"}},
               {:plain_text, %{text: "second chunk"}}
             ]
    end

    @tag :capture_log
    test "no event broadcast for an unregistered-adapter run (no :harness_transcript_events on the wire)" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 2_000)
      wait_until_running(run_id, 20, 2_000)

      :ok = Transcript.subscribe(run_id)

      send(pid, {:transcript_chunk, "raw"})

      # Raw broadcast still fires (legacy backbone)…
      assert_receive {:harness_transcript, ^run_id, 1, "raw"}, 1_000

      # …but events broadcast does NOT, because agent_kind is nil and the
      # parser path returns an empty delta.
      refute_receive {:harness_transcript_events, _, _, _}, 100
    end
  end
end
