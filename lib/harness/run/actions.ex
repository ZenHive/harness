defmodule Harness.Run.Actions do
  @moduledoc false

  import Harness.Run.Actions.Control
  import Harness.Run.Actions.Discernment, only: [maybe_sample_in_run_discernment: 2]
  import Harness.Run.Actions.Recovery, only: [recover_checkout_pollution: 2]
  import Harness.Run.Actions.Settlement, only: [accumulate_token_usage: 2, route_reflex_halt: 2]
  import Harness.Run.Actions.Timeouts, only: [rearm_reviewing_idle: 3, rearm_running_idle: 3]
  import Harness.Run.Actions.Transcript, only: [finalize_transcript: 1, parse_chunk: 2, status_snapshot: 2]
  import Harness.Run.Actions.Worktree, only: [checkout_pollution_reason: 1]

  alias Harness.AgentAdapter.Outcome
  alias Harness.Dashboard.Transcript
  alias Harness.Run.TranscriptSnapshot

  @recoverable_code_reload_states [:reviewing, :recovering, :held]

  @type state :: Harness.Run.state()
  @type data :: map()
  @type event :: term()
  @type handler_result :: term()

  @doc false
  @spec recoverable_code_reload_states() :: [atom()]
  def recoverable_code_reload_states, do: @recoverable_code_reload_states

  # ── Cross-cutting events ──────────────────────────────────────────────────

  # Events handled the same way in every state: status queries, cancellation,
  # the lifetime timeout, and stale messages from tasks already consumed or
  # killed.
  @doc false
  @spec handle_common(event(), term(), state(), data()) :: handler_result()
  def handle_common({:call, from}, :status, state, data) do
    {:keep_state_and_data, [{:reply, from, status_snapshot(state, data)}]}
  end

  def handle_common({:call, from}, :transcript, _state, data) do
    snapshot = TranscriptSnapshot.buffer_only(Transcript.to_binary(data.transcript), data.transcript_seq)
    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  def handle_common({:call, from}, :transcript_events, _state, data) do
    snapshot = %TranscriptSnapshot{
      events: data.transcript_events,
      agent_kind: data.agent_kind,
      seq: data.transcript_seq
    }

    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  # State-agnostic so a chunk that lands during `:committing` / `:reviewing` /
  # `:terminal_linger` still appends — the agent's Port can flush after the
  # gen_statem has already transitioned out of `:running`.
  #
  # Two parallel buffers + broadcasts per chunk: the legacy raw iodata path
  # (Transcript.append/broadcast) keeps `?raw=1` on the run-detail URL alive
  # for one release; the parsed-event path (Transcript.append_chunk/4 +
  # broadcast_events/3) feeds the new `<.transcript_view>` renderer. Subscribers
  # pattern-match whichever shape they want.
  def handle_common(:info, {:transcript_chunk, chunk}, state, data) do
    {trimmed, trimmed_bytes} = Transcript.append(data.transcript, data.transcript_bytes, chunk)
    new_seq = data.transcript_seq + 1
    Transcript.broadcast(data.run_id, new_seq, chunk)

    {new_events, delta, new_parser_state} = parse_chunk(data, chunk)
    if delta != [], do: Transcript.broadcast_events(data.run_id, new_seq, delta)

    data = %{
      data
      | transcript: trimmed,
        transcript_bytes: trimmed_bytes,
        transcript_seq: new_seq,
        transcript_events: new_events,
        transcript_parser_state: new_parser_state
    }

    result = maybe_sample_in_run_discernment(state, data)
    result = rearm_running_idle(state, data, result)
    rearm_reviewing_idle(state, data, result)
  end

  def handle_common({:call, from}, :cancel, state, _data) when state in [:done, :failed] do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_common({:call, from}, {:hold, _interrupt}, :held, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_common({:call, from}, {:hold, _interrupt}, state, _data) when state in [:done, :failed] do
    {:keep_state_and_data, [{:reply, from, {:error, :terminal}}]}
  end

  def handle_common({:call, from}, {:hold, true}, :running, %{agent_run: nil} = data) do
    {:keep_state, %{data | hold_requested: :interrupt}, [{:reply, from, :ok}]}
  end

  def handle_common({:call, from}, {:hold, true}, :running, data) do
    do_hold(data, :interrupt, [{:reply, from, :ok}])
  end

  def handle_common({:call, from}, {:hold, false}, :running, %{hold_requested: hold} = _data)
      when hold in [:graceful, :interrupt] do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_common({:call, from}, {:hold, false}, :running, data) do
    {:keep_state, %{data | hold_requested: :graceful}, [{:reply, from, :ok}]}
  end

  def handle_common({:call, from}, {:hold, _interrupt}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_state}}]}
  end

  def handle_common({:call, from}, {:steer, text}, state, data) when state in [:running, :held] do
    if session_resume_supported?(data) do
      {:keep_state, apply_steer(data, text), [{:reply, from, :ok}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :resume_unsupported}}]}
    end
  end

  def handle_common({:call, from}, :resume, :held, data) do
    do_resume(data, from)
  end

  def handle_common({:call, from}, :resume, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_held}}]}
  end

  def handle_common({:call, from}, :cancel, :running, %{agent_run: nil} = data) do
    # The agent has spawned but its handle has not arrived yet — defer the
    # cancel until {:run_handle, _} lands, so the agent can actually be killed.
    {:keep_state, %{data | cancel_requested: {:cancelled, from}}}
  end

  def handle_common({:call, from}, :cancel, _state, data) do
    do_cancel(data, :cancelled, from)
  end

  def handle_common({:timeout, :lifetime}, :lifetime, state, _data) when state in [:done, :failed, :held] do
    :keep_state_and_data
  end

  def handle_common({:timeout, :lifetime}, :lifetime, _state, data) do
    force_settle_lifetime(data)
  end

  def handle_common({:timeout, :mem_sample}, :mem_sample, state, _data) when state in [:done, :failed, :held] do
    :keep_state_and_data
  end

  def handle_common({:timeout, :mem_sample}, :mem_sample, _state, data) do
    check_memory(data)
  end

  # Stale task messages (a result or DOWN from a task already consumed or
  # killed) and any other unrecognised info — ignored.
  def handle_common(:info, _content, _state, _data), do: :keep_state_and_data

  # Defensive catch-all for any other event type.
  def handle_common(_type, _content, _state, _data), do: :keep_state_and_data

  # ── Cancellation & settling ───────────────────────────────────────────────

  @doc false
  @spec settle_implementer_outcome(data(), Outcome.t()) :: handler_result()
  def settle_implementer_outcome(data, %Outcome{} = outcome) do
    data =
      %{data | agent_outcome: outcome}
      |> finalize_transcript()
      |> accumulate_token_usage(outcome)
      |> clear_operator_steer_after_invocation()

    # Precedence: a user cancel is terminal and must win over reflex re-dispatch,
    # so the reflex clause is gated on `nil` cancel. Checkout pollution routes
    # through the bounded recovery seam before any non-terminal advance.
    case {data.hold_requested, data.cancel_requested, outcome.kind, checkout_pollution_reason(data)} do
      {hold, nil, _kind, nil} when hold in [:graceful, :interrupt] ->
        do_hold(data, hold)

      {false, nil, {:reflex_halted, reason}, nil} ->
        fail(data, route_reflex_halt(data, reason))

      {false, nil, _kind, nil} ->
        {:next_state, :committing, data}

      {_, {reason, from}, _kind, nil} ->
        do_cancel(data, reason, from)

      {_, _, _kind, pollution_reason} when not is_nil(pollution_reason) ->
        recover_checkout_pollution(data, pollution_reason)
    end
  end
end
