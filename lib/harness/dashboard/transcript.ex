defmodule Harness.Dashboard.Transcript do
  @moduledoc """
  PubSub topic and buffer helper for the live stream-json transcript pane
  (Task 50 Pass 2, extended in Task 63 with seq-tagged broadcasts and a shared
  append helper).

  The agent's port output passes through `Harness.AgentAdapter.Driver.loop/7`
  one chunk at a time. The run-wrapping `Harness.Run` gen_statem ingests each
  chunk into a bounded buffer alongside its `Status` snapshot, then publishes
  it here as `{:harness_transcript, run_id, seq, data}`. Subscribers (the
  `Harness.Dashboard.Live` LiveView) fetch the buffer + last `seq` on mount via
  `Harness.Run.transcript/1`, then dedup any broadcasts with `seq <= last_seq`
  that overlapped the snapshot call.

  ## Buffer cap

  The buffer is bounded at `@buffer_bytes` (200 KiB) on both ends of the wire:
  the gen_statem keeps the most recent 200 KiB; the LiveView keeps the most
  recent 200 KiB after appending live chunks. `append/3` is the shared trim
  implementation so producer and consumer can never disagree on what "the last
  200 KiB" means.

  ## PubSub guard

  Broadcast and subscribe are guarded by `Process.whereis(Harness.PubSub)` so a
  driver embedded in a non-dashboard runtime (consumer skipped the dashboard
  subtree) never fails on a missing bus.
  """

  @pubsub Harness.PubSub
  @buffer_bytes 200 * 1024

  @doc "The buffer cap in bytes (200 KiB)."
  @spec buffer_bytes() :: pos_integer()
  def buffer_bytes, do: @buffer_bytes

  @doc "Returns the PubSub topic for `run_id`'s transcript stream."
  @spec topic(String.t()) :: String.t()
  def topic(run_id) when is_binary(run_id), do: "harness:run:" <> run_id <> ":transcript"

  @doc "Subscribes the calling process to `run_id`'s transcript chunks. No-op if PubSub is not running."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) when is_binary(run_id) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.subscribe(@pubsub, topic(run_id))
    else
      :ok
    end
  end

  @doc "Stops the calling process from receiving `run_id`'s transcript chunks."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(run_id) when is_binary(run_id) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic(run_id))
    else
      :ok
    end
  end

  @doc """
  Broadcasts a transcript `chunk` for `run_id` tagged with `seq`.

  Called by the `Harness.Run` gen_statem's `:transcript_chunk` handler, which
  owns the monotonic seq counter and the bounded buffer. Subscribers receive
  `{:harness_transcript, run_id, seq, data}`. Silent no-op when the PubSub
  server is not running.
  """
  @spec broadcast(String.t(), non_neg_integer(), iodata()) :: :ok
  def broadcast(run_id, seq, chunk) when is_binary(run_id) and is_integer(seq) and seq >= 0 do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, topic(run_id), {:harness_transcript, run_id, seq, chunk})
    end

    :ok
  end

  @doc """
  Appends `chunk` to `buffer`, returning `{new_buffer, new_bytes}` trimmed to
  the most recent `buffer_bytes()` (200 KiB).

  Shared between the producer (`Harness.Run` gen_statem holding the snapshot
  buffer) and the consumer (`Harness.Dashboard.Live` holding the live-streamed
  buffer) so both ends agree on the trim semantics. `chunk` may be iodata; the
  return buffer is always binary.
  """
  @spec append(binary(), non_neg_integer(), iodata()) :: {binary(), non_neg_integer()}
  def append(buffer, bytes, chunk) when is_binary(buffer) and is_integer(bytes) and bytes >= 0 do
    chunk_bin = IO.iodata_to_binary(chunk)
    combined = buffer <> chunk_bin
    combined_bytes = bytes + byte_size(chunk_bin)
    trim(combined, combined_bytes)
  end

  @spec trim(binary(), non_neg_integer()) :: {binary(), non_neg_integer()}
  defp trim(buffer, bytes) when bytes <= @buffer_bytes, do: {buffer, bytes}

  defp trim(buffer, _bytes) do
    target = @buffer_bytes
    size = byte_size(buffer)
    start = size - target
    trimmed = binary_part(buffer, start, target)
    {trimmed, byte_size(trimmed)}
  end
end
