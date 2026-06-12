defmodule Harness.Run.TranscriptTest do
  use Harness.RunCase, async: true

  describe "transcript/1 (dashboard backfill snapshot)" do
    test "public run APIs tolerate a pid that has already exited" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert {:error, :not_found} = Run.status(pid)
      assert {:error, :not_found} = Run.transcript(pid)
      assert {:error, :not_found} = Run.transcript_events(pid)
      assert :ok = Run.cancel(pid)
      assert {:error, :not_found} = Run.hold(pid)
      assert {:error, :not_found} = Run.steer(pid, "note")
      assert {:error, :not_found} = Run.resume(pid)
    end

    test "unknown run id resolves to :not_found" do
      assert {:error, :not_found} = Run.transcript("definitely-not-a-run")
    end

    @tag :capture_log
    test "a fresh run reports an empty buffer with seq 0 before any chunks land" do
      {run_id, _pid} = start(adapter: HangingAdapter, lifetime_timeout: 2_000)
      wait_until_running(run_id, 20, 2_000)

      assert {:ok, %{buffer: <<>>, seq: 0}} = Run.transcript(run_id)
    end

    @tag :capture_log
    test "synthetic {:transcript_chunk, _} appends to the buffer and increments seq" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 5_000)
      wait_until_running(run_id, 20, 5_000)

      send(pid, {:transcript_chunk, "one"})
      send(pid, {:transcript_chunk, "two"})
      send(pid, {:transcript_chunk, "three"})

      # The handler runs in the gen_statem's mailbox order, so a follow-up
      # :gen_statem.call only returns after all queued info messages drain.
      assert {:ok, %{buffer: "onetwothree", seq: 3}} = Run.transcript(run_id)
    end

    @tag :capture_log
    test "broadcasts carry seq so subscribers can dedup against the backfill snapshot" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 5_000)
      wait_until_running(run_id, 20, 5_000)

      :ok = Transcript.subscribe(run_id)

      send(pid, {:transcript_chunk, "alpha"})
      send(pid, {:transcript_chunk, "beta"})

      assert_receive {:harness_transcript, ^run_id, 1, "alpha"}, 1_000
      assert_receive {:harness_transcript, ^run_id, 2, "beta"}, 1_000

      assert {:ok, %{buffer: "alphabeta", seq: 2}} = Run.transcript(run_id)
    end

    @tag :capture_log
    test "the buffer is trimmed to 200 KiB but seq keeps counting every chunk" do
      {run_id, pid} = start(adapter: HangingAdapter, lifetime_timeout: 10_000)
      wait_until_running(run_id, 20, 5_000)

      cap = Transcript.buffer_bytes()
      chunk_size = 64 * 1024
      chunk_count = div(cap, chunk_size) + 2

      for i <- 1..chunk_count do
        send(pid, {:transcript_chunk, <<i::8, String.duplicate("x", chunk_size - 1)::binary>>})
      end

      assert {:ok, %{buffer: buffer, seq: seq}} = Run.transcript(run_id)
      assert byte_size(buffer) == cap
      assert seq == chunk_count
    end
  end
end
