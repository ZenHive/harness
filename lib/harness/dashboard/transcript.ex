defmodule Harness.Dashboard.Transcript do
  @moduledoc """
  PubSub topic and buffer helpers for the live transcript pane (Task 50 Pass 2,
  extended in Task 63 with seq-tagged broadcasts and a shared append helper,
  extended in Task 87 with a parsed-event surface).

  The agent's port output passes through `Harness.AgentAdapter.Driver.loop/7`
  one chunk at a time. The run-wrapping `Harness.Run` gen_statem ingests each
  chunk twice:

    * Into the legacy raw iodata buffer (`append/3`, 200 KiB tail cap) and
      broadcasts the raw bytes as `{:harness_transcript, run_id, seq, data}`.
    * Through `Harness.Dashboard.Transcript.Parser.append/3` into the parsed
      event list (`append_chunk/4`, event-count cap), broadcasting the new
      events as `{:harness_transcript_events, run_id, seq, events}`.

  Both shapes ship on the same PubSub topic for one release so `?raw=1` on the
  run-detail URL stays functional as a parser escape hatch. Subscribers
  receive whichever messages they pattern-match.

  ## Caps

    * **Raw buffer** — `@buffer_bytes` (200 KiB), trimmed to the most recent
      tail by `append/3`. Producer and consumer share the helper so they never
      disagree on what "the last 200 KiB" means.
    * **Event list** — `event_count_cap/0` (default 500, configurable via
      `config :harness, :dashboard, transcript_max_events: <pos_integer>`).
      Oldest events drop first when the cap is exceeded — mirrors the raw
      buffer's "keep the recent tail" semantics, but at event granularity.

  ## PubSub guard

  Broadcast and subscribe are guarded by `Process.whereis(Harness.PubSub)` so a
  driver embedded in a non-dashboard runtime (consumer skipped the dashboard
  subtree) never fails on a missing bus.
  """

  alias Harness.Dashboard.Transcript.Parser

  @pubsub Harness.PubSub
  @buffer_bytes 200 * 1024
  @default_event_count_cap 500

  @doc "The raw buffer cap in bytes (200 KiB)."
  @spec buffer_bytes() :: pos_integer()
  def buffer_bytes, do: @buffer_bytes

  @doc """
  The event-list cap (count, not bytes).

  Reads `config :harness, :dashboard, transcript_max_events: <pos_integer>`;
  falls back to `500`. Resolved per-call so an app-config change between
  releases takes effect without restart.
  """
  @spec event_count_cap() :: pos_integer()
  def event_count_cap do
    :harness
    |> Application.get_env(:dashboard, [])
    |> Keyword.get(:transcript_max_events, @default_event_count_cap)
  end

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
  Broadcasts a raw transcript `chunk` for `run_id` tagged with `seq`.

  Called by the `Harness.Run` gen_statem's `:transcript_chunk` handler, which
  owns the monotonic seq counter and the bounded buffer. Subscribers receive
  `{:harness_transcript, run_id, seq, data}`. Silent no-op when the PubSub
  server is not running.

  Paired with `broadcast_events/3`: the gen_statem emits both per chunk so a
  late subscriber can hold either shape (the new event list, the legacy raw
  buffer, or both for `?raw=1` toggle).
  """
  @spec broadcast(String.t(), non_neg_integer(), iodata()) :: :ok
  def broadcast(run_id, seq, chunk) when is_binary(run_id) and is_integer(seq) and seq >= 0 do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, topic(run_id), {:harness_transcript, run_id, seq, chunk})
    end

    :ok
  end

  @doc """
  Broadcasts a parsed `events` list for `run_id` tagged with `seq`.

  Sibling to `broadcast/3`: same topic, distinct envelope. Subscribers receive
  `{:harness_transcript_events, run_id, seq, events}`. `events` is the
  *delta* produced by the parser for the chunk just appended, not the running
  list — the LiveView re-builds its own bounded list from `transcript_events/1`
  on mount and appends each delta as it arrives. Silent no-op when the PubSub
  server is not running.
  """
  @spec broadcast_events(String.t(), non_neg_integer(), [Parser.event()]) :: :ok
  def broadcast_events(run_id, seq, events) when is_binary(run_id) and is_integer(seq) and seq >= 0 and is_list(events) do
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(run_id),
        {:harness_transcript_events, run_id, seq, events}
      )
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

  @doc """
  Feeds `new_chunk` through the per-agent parser, appending fresh events to
  `events` and FIFO-trimming the combined list to `event_count_cap/0`.

  Returns `{new_events, delta, new_parser_state}` — `new_events` is the
  bounded snapshot the producer holds; `delta` is the slice produced by this
  chunk (what `broadcast_events/3` should ship). Splitting the two lets the
  producer's broadcast match Phoenix LiveView's `stream_insert/4` consumer
  model without recomputing the diff.

  The agent-kind dispatch happens inside
  `Harness.Dashboard.Transcript.Parser.append/3`; this helper only owns the
  cap-and-evict policy so producer (`Harness.Run`) and consumer
  (`Harness.Dashboard.Live`) share trim semantics — same shape as `append/3`,
  but at event granularity rather than byte granularity.

  Oldest events drop first when the combined list exceeds the cap, mirroring
  the raw buffer's "keep the recent tail" intent.
  """
  @spec append_chunk(
          [Parser.event()],
          Parser.agent_kind(),
          Parser.parser_state(),
          iodata()
        ) :: {[Parser.event()], [Parser.event()], Parser.parser_state()}
  def append_chunk(events, agent_kind, parser_state, new_chunk) when is_list(events) and is_atom(agent_kind) do
    {delta, new_parser_state} = Parser.append(agent_kind, new_chunk, parser_state)
    {trim_events(events ++ delta), delta, new_parser_state}
  end

  @doc """
  Flushes any trailing partial-line bytes through the parser at port close.

  Wraps `Harness.Dashboard.Transcript.Parser.finalize/2` with the same
  cap-and-evict trim as `append_chunk/4`. Same three-tuple return shape —
  `{new_events, delta, new_parser_state}` — so a parser that buffered a
  complete JSON object without a newline surfaces its drained events both in
  the producer's snapshot and on the wire.
  """
  @spec finalize(
          [Parser.event()],
          Parser.agent_kind(),
          Parser.parser_state()
        ) :: {[Parser.event()], [Parser.event()], Parser.parser_state()}
  def finalize(events, agent_kind, parser_state) when is_list(events) and is_atom(agent_kind) do
    {delta, new_parser_state} = Parser.finalize(agent_kind, parser_state)
    {trim_events(events ++ delta), delta, new_parser_state}
  end

  @spec trim_events([Parser.event()]) :: [Parser.event()]
  defp trim_events(events) do
    cap = event_count_cap()
    count = length(events)

    if count <= cap do
      events
    else
      Enum.drop(events, count - cap)
    end
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
