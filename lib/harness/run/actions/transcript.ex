defmodule Harness.Run.Actions.Transcript do
  @moduledoc false

  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Run.Review
  alias Harness.Run.Status

  @task_supervisor Harness.Run.TaskSupervisor

  @type state :: Harness.Run.state()
  @type data :: map()
  # ── Helpers ───────────────────────────────────────────────────────────────

  @doc false
  @spec status_snapshot(state(), data()) :: Status.t()
  def status_snapshot(state, data) do
    %Status{
      run_id: data.run_id,
      task_id: data.item.id,
      project_name: data.project.name,
      # data.agent_kind is the executing adapter's identity atom (resolved at
      # init). Live runs show the task's requested model until settle; the
      # settled record prefers the agent-reported model when present.
      agent: data.agent_kind,
      model: data.requested_model,
      state: state,
      started_at: data.started_at,
      state_entered_at: data.state_entered_at,
      worktree_path: data.worktree && data.worktree.path,
      agent_diff_size: Map.get(data, :agent_diff_size),
      agent_os_pid: active_agent_os_pid(state, data),
      agent_kind: status_agent_kind(state, data),
      reviewer_adapter: agent_kind_for(data.reviewer_adapter),
      recovery_adapter: agent_kind_for(data.recovery_adapter),
      review_verdict: data.review && data.review.verdict,
      review_warning?: Review.warning?(data.review),
      reason: data.reason,
      held?: state == :held,
      hold_reason: if(state == :held, do: data.hold_reason)
    }
  end

  @doc false
  @spec active_agent_os_pid(state(), data()) :: non_neg_integer() | nil
  def active_agent_os_pid(:reviewing, %{reviewer_run: %AgentRun{os_pid: os_pid}}), do: os_pid
  def active_agent_os_pid(:recovering, %{recovery_run: %AgentRun{os_pid: os_pid}}), do: os_pid
  def active_agent_os_pid(_state, %{agent_run: %AgentRun{os_pid: os_pid}}), do: os_pid
  def active_agent_os_pid(_state, _data), do: nil

  @doc false
  @spec status_agent_kind(state(), data()) :: Outcome.kind() | :recovery_review | nil
  def status_agent_kind(:reviewing, %{reviewer_reprompt_count: count}) when count > 0, do: :recovery_review
  def status_agent_kind(_state, %{agent_outcome: %Outcome{kind: kind}}), do: kind
  def status_agent_kind(_state, _data), do: nil

  @doc false
  @spec stamp_state_entry(state() | :recovery_review, data()) :: data()
  def stamp_state_entry(state, data) do
    Map.put(
      data,
      :state_entered_at,
      Map.put(Map.get(data, :state_entered_at, %{}), state, DateTime.utc_now(:millisecond))
    )
  end

  @doc false
  @spec start_task((-> term())) :: Task.t()
  def start_task(fun) do
    Task.Supervisor.async_nolink(@task_supervisor, fun)
  end

  # Resolves the adapter module back to its `Parser.agent_kind` atom for the
  # transcript parser. Returns `nil` for unregistered adapters (test doubles,
  # ad-hoc invocations) so the run still functions — the parsed-event surface
  # stays empty in that case and only `?raw=1` shows anything in the dashboard.
  @doc false
  @spec agent_kind_for(module()) :: Parser.agent_kind() | nil
  def agent_kind_for(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, kind} -> kind
      {:error, _} -> nil
    end
  end

  @doc false
  @spec init_parser_state(module()) :: Parser.parser_state() | nil
  def init_parser_state(adapter) do
    case agent_kind_for(adapter) do
      nil -> nil
      kind -> Parser.init_state(kind)
    end
  end

  # Feeds a chunk through the parser when the executing adapter resolved to a
  # known `agent_kind`; otherwise threads existing state untouched with an empty
  # delta. The cap-and-evict trim AND the broadcast delta both come from
  # `Transcript.append_chunk/4`'s three-tuple return so the producer never has
  # to recompute either.
  @doc false
  @spec parse_chunk(data(), iodata()) ::
          {[Parser.event()], [Parser.event()], Parser.parser_state() | nil}
  def parse_chunk(%{agent_kind: nil} = data, _chunk) do
    {data.transcript_events, [], data.transcript_parser_state}
  end

  def parse_chunk(%{agent_kind: kind, transcript_events: events, transcript_parser_state: state}, chunk) do
    Transcript.append_chunk(events, kind, state, chunk)
  end

  # Flushes any trailing partial-line bytes the per-agent parser buffered when
  # the agent's Port closed (a complete JSON object/event without a final
  # newline would otherwise never surface in the parsed-event view). Mirrors
  # the per-chunk path: trim via the shared helper, and broadcast the drained
  # delta on a fresh seq so a live subscriber sees the last event too.
  # No-op for unregistered adapters (agent_kind: nil).
  @doc false
  @spec finalize_transcript(data()) :: data()
  def finalize_transcript(%{agent_kind: nil} = data), do: data

  def finalize_transcript(%{agent_kind: kind, transcript_events: events, transcript_parser_state: state} = data) do
    {new_events, delta, new_parser_state} = Transcript.finalize(events, kind, state)

    if delta == [] do
      %{data | transcript_events: new_events, transcript_parser_state: new_parser_state}
    else
      new_seq = data.transcript_seq + 1
      Transcript.broadcast_events(data.run_id, new_seq, delta)

      %{
        data
        | transcript_events: new_events,
          transcript_parser_state: new_parser_state,
          transcript_seq: new_seq
      }
    end
  end
end
