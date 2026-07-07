defmodule Harness.Run.Actions do
  @moduledoc false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentKPI
  alias Harness.AgentRegistry
  alias Harness.AgentRules
  alias Harness.AuditReview
  alias Harness.Config
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Dispatch
  alias Harness.Git
  alias Harness.Lander.Resilience
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.ModelAvailability
  alias Harness.Notification
  alias Harness.Notification.Event, as: NotificationEvent
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Run.MemoryGuard
  alias Harness.Run.Recovery
  alias Harness.Run.Result
  alias Harness.Run.RetryPolicy
  alias Harness.Run.Review
  alias Harness.Run.Status
  alias Harness.Run.TestDbIsolation
  alias Harness.Run.TranscriptSnapshot
  alias Harness.Text
  alias Harness.TokenUsage
  alias Harness.TokenUsage.GrokSession
  alias Harness.Worktree
  alias Harness.Worktree.Isolation
  alias Harness.Worktree.Reaper
  alias Oban.Job

  require Logger

  @task_supervisor Harness.Run.TaskSupervisor

  @semantic_diff_max_bytes 80_000
  @reviewer_transcript_tail_bytes 40_000
  @default_discernment_sample_interval_ms 300_000
  @default_discernment_min_weight 6
  @default_discernment_long_running_ms 600_000
  @default_discernment_min_transcript_bytes 1
  @reviewer_rejection_sample 500
  @reviewer_idle_floor 600_000
  @implementer_idle_floor 600_000
  @reviewer_reprompt_limit 1
  @recoverable_code_reload_states [:reviewing, :recovering, :held]
  @default_mem_threshold_kb 6 * 1024 * 1024
  @default_mem_sample_interval 5_000
  @github_auth_env_scrubs %{"GH_TOKEN" => false, "GITHUB_TOKEN" => false}
  @gh_config_dir Path.join([".harness", "gh-config"])

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
    snapshot = TranscriptSnapshot.buffer_only(data.transcript, data.transcript_seq)
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

  # Aborts an in-flight run: kills the current step task, SIGKILLs the agent if
  # one is running, and settles `failed`. `from` is the caller awaiting a cancel
  # reply, or `nil` for a timeout-triggered abort.
  @doc false
  @spec do_hold(data(), :graceful | :interrupt, [:gen_statem.action()]) :: handler_result()
  def do_hold(data, mode, extra_actions \\ []) do
    terminate_agent(data)
    cancel_task(data.task)
    cancel_task(data.discernment_task)

    data = %{
      data
      | task: nil,
        discernment_task: nil,
        agent_run: nil,
        hold_requested: false,
        hold_reason: mode,
        cancel_requested: nil
    }

    {:next_state, :held, data, extra_actions ++ hold_enter_actions(data)}
  end

  @doc false
  @spec do_resume(data(), :gen_statem.from()) :: handler_result()
  def do_resume(data, from) do
    data = %{data | hold_reason: nil}

    {:next_state, :running, data,
     [
       {:reply, from, :ok},
       {{:timeout, :lifetime}, data.lifetime_timeout, :lifetime},
       {{:timeout, :mem_sample}, data.mem_sample_interval, :mem_sample}
     ]}
  end

  @doc false
  @spec hold_enter_actions(data()) :: [:gen_statem.action()]
  def hold_enter_actions(data) do
    [{{:timeout, :lifetime}, :infinity, :lifetime}] ++ hold_expiry_actions(data)
  end

  @doc false
  @spec hold_expiry_actions(data()) :: [:gen_statem.action()]
  def hold_expiry_actions(%{max_hold_timeout: :infinity}), do: []

  def hold_expiry_actions(%{max_hold_timeout: timeout}) when is_integer(timeout) and timeout > 0 do
    [{:state_timeout, timeout, :held_expired}]
  end

  @doc false
  @spec apply_steer(data(), String.t()) :: data()
  def apply_steer(data, text) do
    feedback =
      case data.operator_feedback do
        nil -> text
        existing -> existing <> "\n\n" <> text
      end

    %{data | operator_feedback: feedback}
  end

  @doc false
  @spec session_resume_supported?(data()) :: boolean()
  def session_resume_supported?(data) do
    AgentAdapter.supports?(data.adapter, :session_resume)
  end

  @doc false
  @spec clear_operator_steer(data()) :: data()
  def clear_operator_steer(data) do
    %{data | operator_feedback: nil}
  end

  @doc false
  @spec clear_operator_steer_after_invocation(data()) :: data()
  def clear_operator_steer_after_invocation(%{operator_feedback: feedback} = data) when is_binary(feedback),
    do: clear_operator_steer(data)

  def clear_operator_steer_after_invocation(data), do: data

  @doc false
  @spec do_cancel(data(), Result.reason(), :gen_statem.from() | nil) :: handler_result()
  def do_cancel(data, reason, from) do
    # Terminate-then-cancel: the adapter SIGKILLs the captured os_pid while its
    # Port is still open, before cancel_task tears down the Port owner (Task 201).
    terminate_agent(data)
    terminate_recovery(data)
    terminate_reviewer(data)
    cancel_task(data.task)
    cancel_task(data.discernment_task)

    data = %{
      data
      | task: nil,
        discernment_task: nil,
        agent_run: nil,
        recovery_run: nil,
        reviewer_run: nil,
        cancel_requested: nil,
        reason: reason
    }

    actions = if from, do: [{:reply, from, :ok}], else: []
    {:next_state, :failed, data, actions}
  end

  # Force-settles `:failed` with `:timed_out` when the lifetime budget elapses.
  # The lifetime timer is the last-resort deadline: it fires regardless of
  # whether `{:run_handle, _}` has arrived, so a hung adapter
  # `build_command`/`invoke` cannot wedge the run forever. Trade-off: with
  # `agent_run: nil` there is nothing to SIGKILL directly — killing the driver
  # task closes its port and a just-spawned OS process whose pid we never
  # received may leak. The boot-time `Harness.Worktree.Sweeper` reaps its
  # working directory across restarts. A deferred cancel caller (a real
  # `cancel/1` that arrived before the agent handle) still gets `:ok`.
  @doc false
  @spec force_settle_lifetime(data()) :: handler_result()
  def force_settle_lifetime(data) do
    # Terminate-then-cancel (Task 201): reap the captured os_pid before the Port
    # owner is torn down.
    terminate_agent(data)
    terminate_recovery(data)
    terminate_reviewer(data)
    cancel_task(data.task)
    cancel_task(data.discernment_task)
    actions = pending_cancel_reply(data)

    data = %{
      data
      | task: nil,
        discernment_task: nil,
        agent_run: nil,
        recovery_run: nil,
        reviewer_run: nil,
        cancel_requested: nil,
        reason: :timed_out
    }

    {:next_state, :failed, data, actions}
  end

  # Settles `failed` with `reason`, replying to a deferred cancel caller if one
  # is waiting — a cancel arrived before the agent handle, then the run failed
  # for another cause before the cancel could be honoured.
  #
  # The agent may still be alive — a driver-task crash leaves its OS process
  # running with nothing left to idle-time it out — so SIGKILL it here. A
  # crashed step must never orphan an agent (and its API quota).
  # `terminate_agent/1` is a no-op when no agent spawned and idempotent when it
  # already exited.
  @doc false
  @spec fail(data(), Result.reason()) :: handler_result()
  def fail(data, reason) do
    # Terminate-then-cancel (Task 201): SIGKILL the captured os_pid before
    # cancel_task closes the Port owner.
    terminate_agent(data)
    terminate_recovery(data)
    terminate_reviewer(data)
    cancel_task(data.discernment_task)

    {:next_state, :failed,
     %{
       data
       | discernment_task: nil,
         agent_run: nil,
         recovery_run: nil,
         reviewer_run: nil,
         cancel_requested: nil,
         reason: reason
     }, pending_cancel_reply(data)}
  end

  # Memory watchdog tick (Task 200): sample the resident memory of each live
  # spawned tree (implementer agent + reviewer); over the ceiling → reap the
  # whole tree and settle :failed, otherwise re-arm. Mechanical — `ps`/`kill`,
  # no judgment, no output parsing.
  @doc false
  @spec check_memory(data()) :: handler_result()
  def check_memory(data) do
    case runaway_tree(data) do
      {role, os_pid, rss_kb} ->
        fail_memory_runaway(data, role, os_pid, rss_kb)

      nil ->
        {:keep_state_and_data, [{{:timeout, :mem_sample}, data.mem_sample_interval, :mem_sample}]}
    end
  end

  @type runaway_role :: :agent | :recovery | :reviewer

  @doc false
  @spec runaway_tree(data()) :: {runaway_role(), non_neg_integer(), non_neg_integer()} | nil
  def runaway_tree(data) do
    candidates = [
      {:agent, data.agent_run},
      {:recovery, data.recovery_run},
      {:reviewer, data.reviewer_run}
    ]

    Enum.find_value(candidates, fn {role, run} ->
      over_threshold(role, run, data.mem_threshold_kb)
    end)
  end

  @doc false
  @spec over_threshold(runaway_role(), AgentRun.t() | nil, pos_integer()) ::
          {runaway_role(), non_neg_integer(), non_neg_integer()} | nil
  def over_threshold(_role, nil, _threshold), do: nil
  def over_threshold(_role, %AgentRun{os_pid: nil}, _threshold), do: nil

  def over_threshold(role, %AgentRun{os_pid: os_pid}, threshold) do
    rss_kb = MemoryGuard.tree_rss_kb(os_pid)
    if rss_kb > threshold, do: {role, os_pid, rss_kb}
  end

  # Force-kills the runaway process tree (the descendant grandchild a plain
  # adapter.terminate/1 would orphan) BEFORE the adapter teardown closes its
  # Port — while the port is open the os_pid still names this run's tree
  # (mirrors the OSProcess.kill ordering note) — then settles :failed.
  @doc false
  @spec fail_memory_runaway(data(), runaway_role(), non_neg_integer(), non_neg_integer()) ::
          handler_result()
  def fail_memory_runaway(data, role, os_pid, rss_kb) do
    MemoryGuard.kill_tree(os_pid)
    terminate_agent(data)
    terminate_recovery(data)
    terminate_reviewer(data)
    cancel_task(data.task)
    cancel_task(data.discernment_task)
    actions = pending_cancel_reply(data)

    reason =
      {:memory_runaway, %{role: role, os_pid: os_pid, rss_kb: rss_kb, threshold_kb: data.mem_threshold_kb}}

    next = %{
      data
      | task: nil,
        discernment_task: nil,
        agent_run: nil,
        recovery_run: nil,
        reviewer_run: nil,
        cancel_requested: nil,
        reason: reason
    }

    {:next_state, :failed, next, actions}
  end

  @doc false
  @spec pending_cancel_reply(data()) :: [:gen_statem.action()]
  def pending_cancel_reply(%{cancel_requested: {_reason, from}}) when is_tuple(from) do
    [{:reply, from, :ok}]
  end

  def pending_cancel_reply(_data), do: []

  @doc false
  @spec cancel_task(Task.t() | nil) :: :ok
  def cancel_task(nil), do: :ok

  def cancel_task(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  @doc false
  @spec terminate_agent(data()) :: :ok
  def terminate_agent(%{agent_run: nil}), do: :ok

  def terminate_agent(%{agent_run: %AgentRun{} = run, adapter: adapter}) do
    adapter.terminate(run)
    :ok
  end

  @doc false
  @spec terminate_reviewer(data()) :: :ok
  def terminate_reviewer(%{reviewer_run: nil}), do: :ok

  def terminate_reviewer(%{reviewer_run: %AgentRun{} = run, reviewer_adapter: adapter}) when is_atom(adapter) do
    adapter.terminate(run)
    :ok
  end

  @doc false
  @spec terminate_recovery(data()) :: :ok
  def terminate_recovery(%{recovery_run: nil}), do: :ok

  def terminate_recovery(%{recovery_run: %AgentRun{} = run, recovery_adapter: adapter}) when is_atom(adapter) do
    adapter.terminate(run)
    :ok
  end

  @doc false
  @spec clear_recovery_run(data()) :: data()
  def clear_recovery_run(data), do: %{data | recovery_run: nil}

  @doc false
  @spec recover_checkout_pollution(data(), Result.reason()) :: handler_result()
  def recover_checkout_pollution(%{recovery_attempts: attempts, recovery_budget: budget} = data, reason)
      when attempts < budget do
    {:next_state, :recovering, %{data | reason: reason, recovery_reason: reason}}
  end

  def recover_checkout_pollution(data, reason), do: {:next_state, :failed, %{data | reason: reason}}

  @doc false
  @spec fail_recovery_dead(data(), String.t()) :: handler_result()
  def fail_recovery_dead(data, report) do
    Logger.info("harness run: recovery declared dead for #{data.run_id}: #{report}")
    terminate_recovery(data)
    cancel_task(data.task)

    {:next_state, :failed,
     %{
       data
       | task: nil,
         recovery_run: nil,
         recovery_outcome: :dead,
         recovery_repaired: nil,
         reason: data.recovery_reason
     }}
  end

  @doc false
  @spec settle_recovery(data(), {:ok, Recovery.t()} | {:error, Recovery.error()}) :: handler_result()
  def settle_recovery(data, {:ok, %Recovery{outcome: :repaired} = recovery}) do
    Logger.info("harness run: recovery repaired #{data.run_id}; resuming through commit + review")

    {:next_state, :committing,
     %{
       data
       | recovery_outcome: :repaired,
         recovery_repaired: recovery.repaired,
         reason: nil,
         recovery_reason: nil
     }}
  end

  def settle_recovery(data, {:ok, %Recovery{outcome: :dead} = recovery}) do
    fail_recovery_dead(%{data | recovery_repaired: recovery.repaired}, recovery.report)
  end

  def settle_recovery(data, {:error, reason}) do
    fail_recovery_dead(data, "Recovery artifact is malformed or missing: #{inspect(reason)}")
  end

  # Reviewer spawn/idle timeout fallback (plan gap 6). Before settling the run
  # :failed, rotate to the next eligible cross-family reviewer carved at
  # route-into-review (`reviewer_candidates`, cross-family by construction). The
  # candidate list is finite, so rotation is bounded by construction; the count
  # is witnessed as a raw fact on the run record. This is MECHANICAL — picking the
  # next candidate, no content inspection to judge whether the work is
  # recoverable — the same class as the missing/malformed re-prompt. Exhausting
  # the candidates settles :review_stuck exactly as before.
  @doc false
  @spec rotate_or_fail_review(data(), String.t()) :: handler_result()
  def rotate_or_fail_review(%{reviewer_candidates: [next | rest]} = data, _report) do
    # Terminate the timed-out reviewer (SIGKILL via its captured os_pid) and tear
    # down its step task BEFORE re-entering :reviewing — same ordering as
    # fail_review_stuck so closing the Port can't race the pid (Task 199 audit).
    terminate_reviewer(data)
    cancel_task(data.task)

    Logger.info(
      "harness run: reviewer timed out for #{data.run_id} — rotating to #{inspect(next)} " <>
        "(rotation #{data.reviewer_rotation_count + 1})"
    )

    data = %{
      data
      | task: nil,
        reviewer_run: nil,
        reviewer_adapter: next,
        reviewer_candidates: rest,
        reviewer_rotation_count: data.reviewer_rotation_count + 1
    }

    # :repeat_state re-runs the :reviewing enter callback, spawning the rotated-to
    # reviewer in the same worktree and re-arming the spawn/idle watchdogs.
    {:repeat_state, data}
  end

  def rotate_or_fail_review(data, report), do: fail_review_stuck(data, report)

  @doc false
  @spec fail_review_stuck(data(), String.t()) :: handler_result()
  def fail_review_stuck(data, report) do
    # Terminate the reviewer (SIGKILL via its captured os_pid) BEFORE tearing
    # down the task that owns its Port — closing the port first could reap/race
    # the pid (Task 199 audit).
    terminate_reviewer(data)
    cancel_task(data.task)
    {:next_state, :failed, clear_reviewer_run(%{data | task: nil, reason: {:review_stuck, report}})}
  end

  @doc false
  @spec clear_reviewer_run(data()) :: data()
  def clear_reviewer_run(data), do: %{data | reviewer_run: nil}

  # Re-arm the idle watchdog on implementer progress — but ONLY once the
  # implementer handle is captured. Before the handle arrives there is no OS pid
  # to reap directly, so the lifetime timeout remains the backstop.
  @doc false
  @spec rearm_running_idle(state(), data(), handler_result()) :: handler_result()
  def rearm_running_idle(:running, %{agent_run: %AgentRun{}} = data, {:keep_state, next_data}) do
    {:keep_state, next_data, [{:state_timeout, running_idle_timeout(data), :implementer_idle_timeout}]}
  end

  def rearm_running_idle(_state, _data, result), do: result

  # Re-arm the idle watchdog on reviewer progress — but ONLY once the reviewer
  # handle is captured (reviewer_run set). Before the handle arrives the spawn
  # watchdog owns the single state_timeout; a stray/early transcript chunk must
  # not replace it with the longer idle window (Task 199 audit).
  @doc false
  @spec rearm_reviewing_idle(state(), data(), handler_result()) :: handler_result()
  def rearm_reviewing_idle(:reviewing, %{reviewer_run: %AgentRun{}} = data, {:keep_state, next_data}) do
    {:keep_state, next_data, [{:state_timeout, reviewing_idle_timeout(data), :reviewer_idle_timeout}]}
  end

  def rearm_reviewing_idle(_state, _data, result), do: result

  @doc false
  @spec reviewer_spawn_timeout_report(data()) :: String.t()
  def reviewer_spawn_timeout_report(data) do
    "Reviewer agent never spawned within #{data.reviewer_spawn_timeout}ms."
  end

  @doc false
  @spec reviewer_idle_timeout_report(data()) :: String.t()
  def reviewer_idle_timeout_report(data) do
    "Reviewer made no progress within #{reviewing_idle_timeout(data)}ms."
  end

  @doc false
  @spec route_reflex_halt(data(), term()) :: Result.reason()
  def route_reflex_halt(data, reason) do
    case Resilience.route({:reflex_halt, reason}, resilience_args(data)) do
      :ok ->
        {:reflex_halted, reason}

      {:cancel, {:blocked, blocked_reason} = cancel_reason} ->
        Logger.warning("harness run: reflex halt blocked task #{data.item.id}: #{blocked_reason}")
        cancel_reason

      {:cancel, cancel_reason} ->
        Logger.info("harness run: reflex halt cancelled task #{data.item.id}: #{inspect(cancel_reason)}")
        cancel_reason

      {:error, route_reason} ->
        Logger.warning("harness run: reflex halt route failed for task #{data.item.id}: #{inspect(route_reason)}")
        {:reflex_halted, reason}
    end
  end

  @doc false
  @spec resilience_args(data()) :: map()
  def resilience_args(data) do
    %{
      "project_name" => data.project.name,
      "run_id" => data.run_id,
      "task_id" => to_string(data.item.id),
      "task_fingerprint" => data.item.fingerprint,
      "agent" => to_string(data.item.agent),
      "branch" => "harness/" <> data.run_id,
      "land_attempt" => data.land_attempt
    }
  end

  # Abnormal gen_statem exit (callback crash, :undef mid-reload, supervisor stop)
  # before a terminal state settled. Persists a minimal failed record, retains the
  # worktree when salvage is possible, and notifies the subscriber so the Oban
  # worker gets a Result instead of a bare {:DOWN, {:undef, _}}.
  @doc false
  @spec crash_settle(data(), state(), term()) :: :ok
  def crash_settle(_data, state, _reason) when state in [:done, :failed], do: :ok

  def crash_settle(data, state, reason) do
    crash_reason = {:run_crashed, normalize_crash_reason(state, reason)}
    result = build_crash_result(data, crash_reason)
    data = stamp_state_entry(:failed, %{data | result: result, reason: crash_reason})
    persist_run_record(data, result)
    finish_worktree(data.worktree, :failed)
    Reaper.untrack(data.run_id)
    notify_subscriber(data.subscriber, data.run_id, result)
    RunFeed.broadcast_settled(status_snapshot(:failed, data))
    :ok
  end

  @doc false
  @spec normalize_crash_reason(state(), term()) :: term()
  def normalize_crash_reason(state, {:undef, _stack} = reason) when state in @recoverable_code_reload_states do
    {:code_reload, state, reason}
  end

  def normalize_crash_reason(state, {:function_clause, _stack} = reason) when state in @recoverable_code_reload_states do
    {:code_reload, state, reason}
  end

  def normalize_crash_reason(_state, reason), do: reason

  @doc false
  @spec build_crash_result(data(), Result.reason()) :: Result.t()
  def build_crash_result(data, crash_reason) do
    %Result{
      run_id: data.run_id,
      task_id: data.item.id,
      state: :failed,
      reason: crash_reason,
      agent_outcome: data.agent_outcome,
      review: data.review,
      reviewer_outcome: data.reviewer_outcome,
      worktree_path: data.worktree && data.worktree.path,
      reviewer_adapter: data.reviewer_adapter,
      reviewer_model: reviewer_model(data),
      agent_diff_size: data.agent_diff_size,
      reviewer_diff_size: data.reviewer_diff_size,
      token_usage: data.token_usage,
      composed_inputs: data.composed_inputs,
      reviewer_reprompt_count: data.reviewer_reprompt_count,
      reviewer_rotation_count: data.reviewer_rotation_count,
      recovery_attempts: data.recovery_attempts,
      recovery_outcome: data.recovery_outcome,
      recovery_repaired: data.recovery_repaired,
      recovery_token_usage: data.recovery_token_usage
    }
  end

  # Builds and persists the final result, tears the worktree down, then delivers
  # it to the subscriber. Teardown errors are logged and swallowed so the result
  # is still delivered, but subscribers do not race test/driver fixture cleanup.
  @doc false
  @spec settle(data(), Result.state()) :: data()
  def settle(data, terminal_state) do
    if terminal_state == :failed, do: maybe_capture_structured_failure(data)
    result = build_result(data, terminal_state)
    data = %{data | result: result}
    persist_run_record(data, result)
    teardown_test_database(data)
    finish_worktree(data.worktree, terminal_state)
    # Worktree is finalized (removed on success / retained on failure) — stop the
    # crash reaper from monitoring this settled run.
    Reaper.untrack(data.run_id)
    notify_settled(data, result)
    notify_subscriber(data.subscriber, data.run_id, result)
    RunFeed.broadcast_settled(status_snapshot(terminal_state, data))
    maybe_enqueue_landing(data, terminal_state)
    data
  end

  # Autonomous merge-train trigger: a run the reviewer approved under a project
  # that opts into landing (`landing_policy: :auto` + a non-empty `target_branch`)
  # enqueues exactly one landing job onto the project's serialized `landing_<name>`
  # queue. Every other terminal state — rejection, failure, `:manual` project, or
  # a project with no `target_branch` — enqueues nothing.
  @doc false
  @spec maybe_enqueue_landing(data(), Result.state()) :: :ok
  def maybe_enqueue_landing(
        %{reason: :approved, project: %Project{landing_policy: :auto, target_branch: tb} = project} = data,
        :done
      )
      when is_binary(tb) and tb != "" do
    %{
      "project_name" => project.name,
      "run_id" => data.run_id,
      "task_id" => to_string(data.item.id),
      "task_fingerprint" => data.item.fingerprint,
      "agent" => to_string(data.item.agent),
      "reviewer" => reviewer_agent_name(data.reviewer_adapter),
      "branch" => "harness/" <> data.run_id,
      "land_attempt" => data.land_attempt
    }
    |> LanderWorker.new_for_project(project)
    |> HarnessOban.insert()
    |> log_landing_enqueue(data.run_id)
  end

  def maybe_enqueue_landing(_data, _terminal_state), do: :ok

  # The reviewer's agent-family name, threaded through the landing job so the
  # post-merge audit can pick a third family (∉ {implementer, reviewer}).
  @doc false
  @spec reviewer_agent_name(module() | nil) :: String.t() | nil
  def reviewer_agent_name(nil), do: nil

  def reviewer_agent_name(reviewer_adapter) do
    case AgentRegistry.agent_for_module(reviewer_adapter) do
      {:ok, agent} -> to_string(agent)
      {:error, _reason} -> nil
    end
  end

  @doc false
  @spec log_landing_enqueue({:ok, Job.t()} | {:error, term()}, String.t()) :: :ok
  def log_landing_enqueue({:ok, _job}, run_id) do
    Logger.info("harness run: enqueued autonomous landing for run #{run_id}")
    :ok
  end

  def log_landing_enqueue({:error, reason}, run_id) do
    Logger.warning("harness run: failed to enqueue landing for run #{run_id}: #{inspect(reason)}")
    :ok
  end

  @doc false
  @spec notify_settled(data(), Result.t()) :: :ok
  def notify_settled(data, %Result{} = result) do
    Notification.notify(%NotificationEvent{
      type: :settled,
      task_id: to_string(data.item.id),
      run_id: data.run_id,
      project: data.project.name,
      branch: "harness/" <> data.run_id,
      land_attempt: data.land_attempt,
      outcome: Dispatch.summarize_result(result)
    })
  end

  @doc false
  @spec build_result(data(), Result.state()) :: Result.t()
  def build_result(data, terminal_state) do
    %Result{
      run_id: data.run_id,
      task_id: data.item.id,
      state: terminal_state,
      reason: data.reason,
      agent_outcome: data.agent_outcome,
      review: data.review,
      reviewer_outcome: data.reviewer_outcome,
      worktree_path: data.worktree && data.worktree.path,
      reviewer_adapter: data.reviewer_adapter,
      reviewer_model: reviewer_model(data),
      agent_diff_size: data.agent_diff_size,
      reviewer_diff_size: data.reviewer_diff_size,
      token_usage: data.token_usage,
      composed_inputs: data.composed_inputs,
      reviewer_reprompt_count: data.reviewer_reprompt_count,
      reviewer_rotation_count: data.reviewer_rotation_count,
      recovery_attempts: data.recovery_attempts,
      recovery_outcome: data.recovery_outcome,
      recovery_repaired: data.recovery_repaired,
      recovery_token_usage: data.recovery_token_usage
    }
  end

  # Parses the just-settled attempt's transcript for token usage and sums it into
  # the run's running total, so a multi-attempt run's burn is attributable.
  # `agent_kind: nil` (test doubles, unregistered adapters) parses to an empty
  # usage, so the total stays an empty usage — never a crash.
  #
  # Grok is the exception: its stdout omits usage entirely, so the figure is
  # recovered from grok's on-disk session log (`GrokSession`). That log records a
  # *cumulative* total across `--continue` attempts, so the recovered value
  # REPLACES the running total rather than summing per attempt; only when
  # recovery yields nothing do we fall back to the (empty) stdout parse.
  @doc false
  @spec accumulate_token_usage(data(), Outcome.t()) :: data()
  def accumulate_token_usage(%{agent_kind: :grok} = data, %Outcome{output: output}) do
    case GrokSession.usage(output) do
      %TokenUsage{} = recovered when recovered.total != nil -> %{data | token_usage: recovered}
      _ -> %{data | token_usage: TokenUsage.add(data.token_usage, TokenUsage.parse(:grok, output))}
    end
  end

  def accumulate_token_usage(data, %Outcome{output: output}) do
    attempt = TokenUsage.parse(data.agent_kind, output)
    %{data | token_usage: TokenUsage.add(data.token_usage, attempt)}
  end

  @doc false
  @spec accumulate_recovery_token_usage(data(), Outcome.t()) :: data()
  def accumulate_recovery_token_usage(data, %Outcome{output: output}) do
    attempt = TokenUsage.parse(agent_kind_for(data.recovery_adapter), output)
    %{data | recovery_token_usage: TokenUsage.add(data.recovery_token_usage, attempt)}
  end

  @doc false
  @spec persist_run_record(data(), Result.t()) :: :ok
  def persist_run_record(data, %Result{} = result) do
    result
    |> LogRecord.from_result(
      batch_id: data.batch_id,
      agent: data.item.agent,
      requested_model: data.requested_model,
      adapter: data.adapter,
      project_name: data.project.name,
      duration_ms: run_duration_ms(data),
      started_at: data.started_at,
      state_entered_at: data.state_entered_at,
      domains: data.item.domains,
      task_fingerprint: data.item.fingerprint,
      reviewer_model: reviewer_model(data)
    )
    |> ResultStore.record_run(data.result_store)
    |> log_store_error(result.run_id)
  end

  @doc false
  @spec log_store_error(:ok | {:error, term()}, String.t()) :: :ok
  def log_store_error(:ok, _run_id), do: :ok

  def log_store_error({:error, reason}, run_id) do
    Logger.warning("harness run: failed to persist run record #{run_id}: #{inspect(reason)}")
    :ok
  end

  @doc false
  @spec run_duration_ms(data()) :: non_neg_integer()
  def run_duration_ms(data) do
    max(0, System.monotonic_time(:millisecond) - data.started_at_ms)
  end

  @doc false
  @spec notify_subscriber(pid() | nil, String.t(), Result.t()) :: :ok
  def notify_subscriber(nil, _run_id, _result), do: :ok

  def notify_subscriber(subscriber, run_id, result) do
    send(subscriber, {:harness_run, run_id, result})
    :ok
  end

  @doc false
  @spec finish_worktree(Worktree.t() | nil, Result.state()) :: :ok
  def finish_worktree(nil, _terminal_state), do: :ok

  def finish_worktree(%Worktree{} = worktree, terminal_state) do
    outcome = if terminal_state == :done, do: :success, else: :failure

    case Worktree.finish(worktree, outcome) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness run: worktree finish failed for #{worktree.path}: #{inspect(reason)}")

        :ok
    end
  end

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

  # The first dispatch runs the task prompt fresh; an operator-steered resume
  # re-enters the agent's session with the steer prompt. There is no repair
  # loop — whatever the implementer leaves behind is the reviewer's to judge.
  @doc false
  @spec build_invocation(data()) :: Invocation.t()
  def build_invocation(%{operator_feedback: feedback} = data) when is_binary(feedback) do
    invocation(data, operator_steer_prompt(data), :resume)
  end

  def build_invocation(data) do
    invocation(data, data.item.prompt, nil)
  end

  @doc false
  @spec invocation(data(), String.t(), :resume | nil) :: Invocation.t()
  def invocation(data, prompt, session) do
    %Invocation{
      prompt: prompt,
      cwd: data.worktree.path,
      log_tag: data.item.id,
      session: session,
      model: data.requested_model,
      rule_content: agent_rule_content(data.project),
      permission_mode: :autonomous,
      adapter_opts: data.adapter_opts,
      env: in_run_env(data)
    }
  end

  @doc false
  @spec run_env(Project.t(), String.t(), %{optional(String.t()) => String.t() | false}) :: %{
          optional(String.t()) => String.t() | false
        }
  def run_env(%Project{} = project, run_id, env) when is_map(env) and is_binary(run_id) do
    env
    |> scrub_github_auth_env()
    |> Map.merge(TestDbIsolation.env(project, run_id))
  end

  @doc false
  @spec in_run_env(data()) :: %{optional(String.t()) => String.t() | false}
  def in_run_env(%{env: env, worktree: %Worktree{path: path}}) do
    env
    |> Map.put("GH_CONFIG_DIR", Path.join(path, @gh_config_dir))
    |> Harness.RmapPath.ensure_agent_env()
  end

  @doc false
  @spec scrub_github_auth_env(%{optional(String.t()) => String.t() | false}) :: %{
          optional(String.t()) => String.t() | false
        }
  def scrub_github_auth_env(env) when is_map(env) do
    # Reach false positive triage: false is the Invocation env scrub payload,
    # not boolean membership. Task 25's Port env contract is %{var => value | false}.
    Map.merge(env, @github_auth_env_scrubs)
  end

  @doc false
  @spec teardown_test_database(data()) :: :ok
  def teardown_test_database(%{project: %Project{} = project, worktree: %Worktree{path: path}, run_id: run_id}) do
    TestDbIsolation.teardown(project, path, run_id)
  end

  def teardown_test_database(_data), do: :ok

  @doc false
  @spec tag_composed_input(AgentRun.t(), data()) :: AgentAdapter.composed_input()
  def tag_composed_input(%AgentRun{composed_input: input}, data) when is_map(input) do
    input
    |> Map.put(:attempt, length(data.composed_inputs))
    |> Map.put(:phase, composed_input_phase(input, data))
  end

  def tag_composed_input(%AgentRun{}, data) do
    %{
      executable: "",
      argv: [],
      rule_channel: data.adapter.rule_channel(),
      prompt: "",
      session: nil,
      rule_files: [],
      attempt: length(data.composed_inputs),
      phase: composed_input_phase_for_data(data)
    }
  end

  @doc false
  @spec composed_input_phase(AgentAdapter.composed_input(), data()) :: :initial | :steer
  def composed_input_phase(%{session: :resume}, _data), do: :steer

  def composed_input_phase(_input, data), do: composed_input_phase_for_data(data)

  @doc false
  @spec composed_input_phase_for_data(data()) :: :initial | :steer
  def composed_input_phase_for_data(%{operator_feedback: feedback}) when is_binary(feedback), do: :steer
  def composed_input_phase_for_data(_data), do: :initial

  @doc false
  @spec operator_steer_prompt(data()) :: String.t()
  def operator_steer_prompt(%{operator_feedback: feedback}) when is_binary(feedback) do
    """
    An operator has reviewed your progress and sent this guidance:

    #{feedback}
    """
  end

  # ── The gate: routing into review and settling on the verdict artifact ───

  # Every committed worktree goes to the reviewer — THE gate. There is no
  # mechanical verification step; the reviewer runs the project's checks itself
  # and writes the verdict artifact harness reads. A run with no available
  # cross-family reviewer cannot be gated, so it fails (the task goes back to
  # the queue for re-dispatch when one is available).
  @doc false
  @spec route_to_review(data()) :: handler_result()
  def route_to_review(data) do
    case select_reviewers(data) do
      {:ok, [primary | candidates]} ->
        # Capture the implementer's final SHA ONCE, here at the single entry into
        # review. `measure_reviewer_diff/2` spans from this baseline, so a
        # Task-203 re-prompt OR a timeout rotation (both `:repeat_state`, which
        # never re-routes) keeps the original baseline and the fix-diff KPI counts
        # the WHOLE review — including a first pass that fixed-then-exited before
        # its verdict. `candidates` is the ordered cross-family fallback set the
        # reviewer-timeout rotation (`rotate_or_fail_review/2`) draws from.
        {:next_state, :reviewing,
         %{
           data
           | reviewer_adapter: primary,
             reviewer_candidates: candidates,
             reviewer_pre_review_sha: current_sha(data)
         }}

      {:error, reason} ->
        report = "No cross-family reviewer adapter available: #{inspect(reason)}"
        {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
    end
  end

  @doc false
  @spec route_after_dispatch(data()) :: handler_result()
  def route_after_dispatch(%{review_only?: true} = data) do
    diff_size = data.review_only_agent_diff_size || 0

    data
    |> Map.put(:agent_diff_size, diff_size)
    |> Map.put(:implementer_empty_diff?, diff_size == 0)
    |> route_to_review()
  end

  def route_after_dispatch(data), do: {:next_state, :running, data}

  @doc false
  @spec maybe_validate_implementer_isolation(data()) ::
          :ok | {:error, {:worktree_isolation_unsupported, module(), String.t()}}
  def maybe_validate_implementer_isolation(%{review_only?: true}), do: :ok

  def maybe_validate_implementer_isolation(data) do
    Isolation.validate(
      data.adapter,
      AgentAdapter.supports?(data.adapter, :worktree_isolation),
      worktree_isolation_limitation(data.adapter)
    )
  end

  # The verdict artifact is read mechanically — approve settles :done, reject
  # settles :failed with the reviewer's report, an unreadable artifact settles
  # :failed as review_stuck. What the work MEANS was the reviewer's judgment;
  # this function only routes on what it wrote.
  @doc false
  @spec settle_review(data(), {:ok, Review.t()} | {:error, Review.error()}) :: handler_result()
  def settle_review(data, {:ok, %Review{verdict: :approve} = review}) do
    {:next_state, :done, clear_operator_steer(%{data | review: review, reason: :approved})}
  end

  def settle_review(data, {:ok, %Review{verdict: :reject} = review}) do
    {:next_state, :failed, %{data | review: review, reason: {:review_rejected, review.report}}}
  end

  # Unreadable verdict — the recoverable case (Task 203, generalized to cover a
  # MALFORMED artifact alongside a MISSING one). On the FIRST miss only, re-enter
  # :reviewing to re-invoke the same reviewer in the same worktree with a terse
  # nudge (see `reviewer_reprompt/1`); `:repeat_state` re-runs the enter callback,
  # re-arming the spawn/idle watchdogs identically to the first pass. The clause
  # matches ANY `{:error, _}` read result — harness inspects no content to judge
  # whether the verdict is recoverable; it simply re-issues the mandatory write
  # once. A second miss (count already at the limit) falls through to the honest
  # :review_stuck failure below — no loop.
  def settle_review(%{reviewer_reprompt_count: count} = data, {:error, reason}) when count < @reviewer_reprompt_limit do
    Logger.info(
      "harness run: reviewer verdict unreadable (#{inspect(reason)}) for #{data.run_id} — " <>
        "re-prompting once (attempt #{count + 1})"
    )

    {:repeat_state, %{stamp_state_entry(:recovery_review, data) | reviewer_reprompt_count: count + 1, task: nil}}
  end

  def settle_review(data, {:error, :missing}) do
    report = "Reviewer wrote no #{Review.artifact_path()} verdict artifact."
    {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
  end

  def settle_review(data, {:error, {:malformed, detail}}) do
    report = "Reviewer verdict artifact is malformed: #{inspect(detail)}"
    {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
  end

  # Resolves the ordered cross-family reviewer set for a run. The head is the
  # primary reviewer; the tail is the rotation fallback the reviewer-timeout
  # path (`rotate_or_fail_review/2`) draws from. Auto-selection returns the whole
  # prioritized registry slate; an explicit pin returns a one-element list; an
  # explicit list is an operator-supplied rotation order (each element validated
  # cross-family + dispatchable). Empty ⇒ `:review_stuck`.
  @doc false
  @spec select_reviewers(data()) :: {:ok, [module(), ...]} | {:error, term()}
  def select_reviewers(%{reviewer: nil} = data) do
    case auto_reviewer_modules(data) do
      [] -> {:error, {:no_cross_family_reviewer, data.item.agent}}
      modules -> {:ok, modules}
    end
  end

  def select_reviewers(%{reviewer: reviewers} = data) when is_list(reviewers) do
    resolve_reviewer_list(data, reviewers)
  end

  def select_reviewers(%{reviewer: reviewer} = data) do
    with {:ok, module} <- resolve_single_reviewer(data, reviewer), do: {:ok, [module]}
  end

  # The full prioritized cross-family slate from the registry — every installed,
  # reviewer-eligible agent that is not the implementer's family, ordered by
  # soft availability and historical rejection rate. The list is the rotation
  # order on a reviewer timeout, not just the single auto-pick.
  @doc false
  @spec auto_reviewer_modules(data()) :: [module()]
  def auto_reviewer_modules(data) do
    implementer = data.item.agent

    AgentRegistry.agents()
    |> Enum.reject(fn {agent, _module} -> agent == implementer end)
    |> Enum.filter(fn {_agent, module} -> reviewer_dispatchable?(module) end)
    |> prioritize_reviewers(reviewer_rejection_rates())
    |> Enum.map(fn {_agent, module} -> module end)
  end

  # An explicit reviewer rotation order: resolve + validate each in turn, failing
  # fast on the first invalid pin (mirrors the single-explicit refusal semantics).
  @doc false
  @spec resolve_reviewer_list(data(), [atom() | module()]) :: {:ok, [module(), ...]} | {:error, term()}
  def resolve_reviewer_list(data, reviewers) do
    reviewers
    |> Enum.reduce_while([], fn reviewer, acc ->
      case resolve_single_reviewer(data, reviewer) do
        {:ok, module} -> {:cont, [module | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      [] -> {:error, {:no_cross_family_reviewer, data.item.agent}}
      modules -> {:ok, Enum.reverse(modules)}
    end
  end

  @doc false
  @spec resolve_single_reviewer(data(), atom() | module()) :: {:ok, module()} | {:error, term()}
  def resolve_single_reviewer(data, reviewer) do
    with {:ok, module} <- resolve_reviewer(reviewer),
         :ok <- ensure_cross_family_reviewer(data.item.agent, module),
         true <- explicit_reviewer_dispatchable?(module) || {:error, {:reviewer_unavailable, module}} do
      {:ok, module}
    end
  end

  # Orders cross-family reviewer candidates, deprioritizing transiently
  # unavailable adapters and high rejection rates. A stable sort by availability
  # AS A SOFT HINT and each candidate's historical rejection rate AS a reviewer
  # (`rates`, keyed by adapter module): a busy reviewer sinks below an available
  # one, and a reviewer that rejects too freely sinks among equally available
  # peers. Advisory only — it reorders, never removes (no blacklist).
  # `@doc false` public so the routing decision is unit-testable without a real
  # auto-selection run (which needs installed agent CLIs).
  @doc false
  @spec prioritize_reviewers([{atom(), module()}], %{optional(module()) => float()}) :: [{atom(), module()}]
  def prioritize_reviewers(candidates, rates) when is_list(candidates) and is_map(rates) do
    Enum.sort_by(candidates, fn {_agent, module} -> {availability_rank(module), Map.get(rates, module, 0.0)} end)
  end

  # Advisory cross-family tiebreaker: among equally-dispatchable reviewers,
  # prefer the one with the lower historical rejection rate AS a reviewer, so a
  # reviewer that rejects too freely is deprioritized (never blacklisted —
  # unmeasured reviewers default to 0.0 and the stable sort preserves registry
  # order when there is no data). Best-effort: a disabled/erroring store yields
  # an empty map and the original registry order stands.
  @doc false
  @spec reviewer_rejection_rates() :: %{optional(module()) => float()}
  def reviewer_rejection_rates do
    case ResultStore.list_run_records(limit: @reviewer_rejection_sample) do
      {:ok, records} ->
        records
        |> AgentKPI.aggregate_reviewer_rejections()
        |> Map.new(fn {module, metrics} -> {module, metrics.rejection_rate} end)

      _error ->
        %{}
    end
  end

  @doc false
  @spec resolve_reviewer(atom() | module()) :: {:ok, module()} | {:error, term()}
  def resolve_reviewer(reviewer) when is_atom(reviewer) do
    case AgentRegistry.module_for_agent(reviewer) do
      {:ok, module} ->
        {:ok, module}

      {:error, _reason} ->
        if Code.ensure_loaded?(reviewer) and function_exported?(reviewer, :build_command, 1) do
          {:ok, reviewer}
        else
          {:error, {:unknown_reviewer, reviewer}}
        end
    end
  end

  @doc false
  @spec ensure_cross_family_reviewer(atom(), module()) :: :ok | {:error, term()}
  def ensure_cross_family_reviewer(implementer, reviewer_module) do
    case AgentRegistry.agent_for_module(reviewer_module) do
      {:ok, ^implementer} -> {:error, {:same_family_reviewer, implementer, reviewer_module}}
      _other -> :ok
    end
  end

  @doc false
  @spec availability_rank(module()) :: 0 | 1
  def availability_rank(module), do: if(AgentRegistry.available?(module), do: 0, else: 1)

  # Reviewer-dispatchability is governed by installed? and reviewer_eligible?.
  # The implementer-level AgentSettings.enabled? flag is deliberately NOT a
  # reviewer gate. The two roles are orthogonal: `enabled?` answers "may this
  # agent IMPLEMENT?", `reviewer_eligible?` answers "may it REVIEW?". Coupling
  # them made "reviewer-only" (disabled implementer + eligible reviewer)
  # unexpressable — a Claude pinned as the dedicated reviewer but disabled as an
  # implementer was rejected as {:reviewer_unavailable, Claude}, settling every
  # run :review_stuck. To bar an agent from BOTH roles, turn off both flags.
  #
  # AgentRegistry.available?/1 is also deliberately NOT a reviewer gate. Its
  # moduledoc defines availability as a restart-cleared soft latency hint, so it
  # belongs in prioritize_reviewers/2 ordering only. Treating it as a hard
  # eligibility filter can empty the whole cross-family slate and discard
  # completed implementer work before any reviewer is tried.
  @doc false
  @spec reviewer_dispatchable?(module()) :: boolean()
  def reviewer_dispatchable?(module) do
    AgentRegistry.installed?(module) and
      reviewer_eligible?(module)
  end

  # Reviewer-eligibility gate, distinct from the implementer-level
  # AgentSettings.enabled? flag: an ineligible agent may still implement, it just
  # can't be picked (auto or explicit) as THE gate; conversely a disabled
  # implementer that is reviewer-eligible CAN still be the gate (reviewer-only).
  # Operator-set and persisted via AgentSettings (Task 182), seeded from its
  # in-code default ([:pi]) on first boot — Pi/OSS models aren't yet trusted to
  # run the checks + write a sound verdict (Task 181). Unknown module ⇒ eligible
  # (default-allow).
  @doc false
  @spec reviewer_eligible?(module()) :: boolean()
  def reviewer_eligible?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> AgentSettings.reviewer_eligible?(agent)
      {:error, _reason} -> true
    end
  end

  @doc false
  @spec explicit_reviewer_dispatchable?(module()) :: boolean()
  def explicit_reviewer_dispatchable?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, _agent} -> reviewer_dispatchable?(module)
      {:error, _reason} -> AgentRegistry.available?(module)
    end
  end

  @doc false
  @spec run_recovery(data(), pid()) ::
          {:ok, %{outcome: Outcome.t(), recovery: {:ok, Recovery.t()} | {:error, Recovery.error()}}}
          | {:error, term()}
  def run_recovery(%{recovery_adapter: adapter} = data, parent) when is_atom(adapter) do
    with {:ok, %Outcome{} = outcome} <-
           run_driver(data, adapter, recovery_invocation(data), recovery_driver_opts(data, parent)) do
      {:ok, %{outcome: outcome, recovery: Recovery.read(data.worktree.path)}}
    end
  end

  @doc false
  @spec recovery_invocation(data()) :: Invocation.t()
  def recovery_invocation(data) do
    repo_path = Project.repo_path(data.project)

    %Invocation{
      prompt: Recovery.prompt(recovery_context(data, repo_path)),
      cwd: data.worktree.path,
      log_tag: "#{data.item.id}-recovery",
      model: data.requested_model,
      rule_content: agent_rule_content(data.project),
      permission_mode: :autonomous,
      adapter_opts: data.reviewer_adapter_opts,
      env: Map.put(in_run_env(data), "HARNESS_RECOVERY_REPO", repo_path)
    }
  end

  @doc false
  @spec recovery_context(data(), String.t()) :: Recovery.context()
  def recovery_context(data, repo_path) do
    %{
      reason: data.recovery_reason,
      repo_path: repo_path,
      git_status: git_status(data.worktree.path),
      transcript_tail: transcript_tail(data.transcript),
      check_output: recovery_check_output(data.recovery_reason, repo_path)
    }
  end

  @doc false
  @spec recovery_check_output(Result.reason() | nil, String.t()) :: String.t()
  def recovery_check_output({:checkout_polluted, status}, _repo_path) when is_binary(status), do: status
  def recovery_check_output(_reason, repo_path), do: git_status(repo_path)

  @doc false
  @spec git_status(String.t()) :: String.t()
  def git_status(path) do
    case Git.run(["status", "--porcelain"], path) do
      {:ok, status} -> status
      {:error, reason} -> "git status failed: #{inspect(reason)}"
    end
  end

  @doc false
  @spec recovery_driver_opts(data(), pid()) :: keyword()
  def recovery_driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:recovery_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, reviewer_idle_timeout(data.idle_timeout))
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  # Runs the reviewer agent in the implementer's worktree, commits whatever it
  # changed (its own fixes), measures the reviewer's own diff, and reads the
  # verdict artifact. The artifact read result rides inside the :ok tuple so a
  # missing/malformed verdict still carries the outcome + diff evidence back to
  # the gen_statem instead of discarding it.
  @doc false
  @spec run_reviewer(data(), pid()) ::
          {:ok,
           %{
             outcome: Outcome.t(),
             reviewer_diff_size: non_neg_integer(),
             review: {:ok, Review.t()} | {:error, Review.error()}
           }}
          | {:error, term()}
  def run_reviewer(data, parent) do
    # Set once at the single route-into-review entry (`route_to_review/1`) so the
    # fix-diff spans the whole review across any Task-203 re-prompt; `||` only
    # guards the degenerate nil (a run that reached review without routing).
    pre_review_sha = data.reviewer_pre_review_sha || current_sha(data)

    with {:ok, %Outcome{} = outcome} <-
           run_driver(data, data.reviewer_adapter, reviewer_invocation(data), reviewer_driver_opts(data, parent)),
         {:ok, _status, _total_diff_size} <- commit_worktree(data, data.worktree, reviewer_commit_message(data)) do
      {:ok,
       %{
         outcome: outcome,
         reviewer_diff_size: measure_reviewer_diff(data, pre_review_sha),
         review: Review.read(data.worktree.path)
       }}
    end
  end

  # Changed-line count of the reviewer's own commits — the "how much fixing was
  # needed" KPI signal. Zero means the implementer's work needed no fixes.
  # Measurement failures degrade to 0 rather than failing the run: the verdict
  # artifact, not this number, is the gate.
  @doc false
  @spec measure_reviewer_diff(data(), String.t()) :: non_neg_integer()
  def measure_reviewer_diff(data, pre_review_sha) do
    case Worktree.diff_size_since(data.worktree, pre_review_sha) do
      {:ok, diff_size} ->
        diff_size

      {:error, reason} ->
        Logger.warning("harness run: reviewer diff measurement failed for #{data.run_id}: #{inspect(reason)}")
        0
    end
  end

  @doc false
  @spec reviewer_invocation(data()) :: Invocation.t()
  def reviewer_invocation(data) do
    %Invocation{
      prompt: reviewer_invocation_prompt(data),
      cwd: data.worktree.path,
      log_tag: "#{data.item.id}-review",
      model: reviewer_model(data),
      rule_content: agent_rule_content(data.project),
      permission_mode: :autonomous,
      adapter_opts: data.reviewer_adapter_opts,
      env: in_run_env(data)
    }
  end

  @doc false
  @spec agent_rule_content(Project.t()) :: String.t()
  def agent_rule_content(%Project{languages: languages}), do: AgentRules.render_for_languages(languages)

  # The reviewer has no task-pin model axis (the task's `model` pins only the
  # implementer), so it resolves from the selected reviewer adapter's agent:
  # reviewer override > shared per-agent default. A nil result for a model-capable
  # reviewer is rejected by ensure_reviewer_model_available/1, never silently
  # passed to the reviewer CLI as its ambient default.
  @doc false
  @spec reviewer_model(data()) :: String.t() | nil
  def reviewer_model(%{reviewer_adapter: reviewer_adapter, reviewer_agent_resolver: resolver})
      when is_atom(reviewer_adapter) and not is_nil(reviewer_adapter) and is_function(resolver, 1) do
    case resolver.(reviewer_adapter) do
      {:ok, agent} -> Config.reviewer_model(agent)
      {:error, _reason} -> nil
    end
  end

  def reviewer_model(_data), do: nil

  @doc false
  @spec reviewer_model_available?(data()) :: :ok | {:error, term()}
  def reviewer_model_available?(%{reviewer_adapter: reviewer_adapter} = data) when is_atom(reviewer_adapter) do
    ensure_reviewer_model_available(data)
  end

  @doc false
  @spec ensure_reviewer_model_available(data()) :: :ok | {:error, term()}
  def ensure_reviewer_model_available(%{reviewer_adapter: reviewer_adapter, reviewer_agent_resolver: resolver})
      when is_atom(reviewer_adapter) and is_function(resolver, 1) do
    case resolver.(reviewer_adapter) do
      {:ok, agent} -> check_reviewer_model(reviewer_adapter, agent)
      {:error, _} -> :ok
    end
  end

  def ensure_reviewer_model_available(%{reviewer_adapter: reviewer_adapter}) do
    case AgentRegistry.agent_for_module(reviewer_adapter) do
      {:ok, agent} -> check_reviewer_model(reviewer_adapter, agent)
      {:error, _} -> :ok
    end
  end

  # The reviewer is the most exposed model-less path — it has no task-pin axis,
  # so a model-capable reviewer adapter with no configured reviewer/agent model
  # is rejected before the reviewer is dispatched, never silently using the
  # reviewer CLI's ambient default.
  @doc false
  @spec check_reviewer_model(module(), atom()) :: :ok | {:error, term()}
  def check_reviewer_model(reviewer_adapter, agent) do
    model = Config.reviewer_model(agent)

    cond do
      is_nil(model) and AgentAdapter.requires_model?(reviewer_adapter) ->
        {:error, {:model_required, agent}}

      ModelAvailability.available?(agent, model) ->
        :ok

      true ->
        {:error, {:unavailable, agent, model, available: ModelAvailability.list_available_ids(agent)}}
    end
  end

  @doc false
  @spec maybe_capture_structured_failure(data()) :: :ok
  def maybe_capture_structured_failure(%{adapter: adapter, reason: reason} = data) when is_atom(adapter) do
    case ModelAvailability.structured_quota_signal(reason) do
      {:ok, _seconds, _model} ->
        :ok = AgentRegistry.mark_unavailable(adapter, reason, model: data.requested_model)

      :error ->
        :ok
    end
  end

  @doc false
  @spec reviewer_driver_opts(data(), pid()) :: keyword()
  def reviewer_driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:reviewer_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, reviewer_idle_timeout(data.idle_timeout))
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  # Idle window for the gen_statem-level :running watchdog. The explicit
  # :implementer_idle_timeout run opt exists so tests can prove the mechanics
  # without waiting for the production floor; normal dispatches use idle_timeout
  # with the implementer floor below.
  @doc false
  @spec running_idle_timeout(data()) :: timeout()
  def running_idle_timeout(%{implementer_idle_timeout: idle}) when not is_nil(idle), do: idle

  def running_idle_timeout(data), do: implementer_idle_timeout(data.idle_timeout)

  # Floors the implementer-phase idle window at @implementer_idle_floor so a
  # silent compile/test/dialyzer command cannot trip the watchdog. `nil` becomes
  # the floor; explicit lower values are raised to it; explicit higher values
  # win. `@doc false` public so the floor is unit-testable without a live run.
  @doc false
  @spec implementer_idle_timeout(timeout() | nil) :: timeout()
  def implementer_idle_timeout(nil), do: @implementer_idle_floor
  def implementer_idle_timeout(:infinity), do: :infinity
  def implementer_idle_timeout(idle) when is_integer(idle), do: max(idle, @implementer_idle_floor)

  # Idle window for the gen_statem-level :reviewing watchdog. An explicit
  # `:reviewing_idle_timeout` run opt wins (tests); otherwise the same floor as
  # the Driver's reviewing idle window.
  @doc false
  @spec reviewing_idle_timeout(data()) :: pos_integer()
  def reviewing_idle_timeout(%{reviewing_idle_timeout: idle}) when is_integer(idle), do: idle

  def reviewing_idle_timeout(data), do: reviewer_idle_timeout(data.idle_timeout)

  # Floors the reviewing-phase idle window at @reviewer_idle_floor so a silent
  # check run can't idle-kill the reviewer before it writes the verdict (Task
  # 181). `nil` (no caller override → Driver applies its 5-min default) becomes
  # the floor; an explicit idle_timeout below the floor is raised to it; an
  # explicit higher value wins. `@doc false` public so the floor is unit-testable
  # without a live reviewer run.
  @doc false
  @spec reviewer_idle_timeout(timeout() | nil) :: timeout()
  def reviewer_idle_timeout(nil), do: @reviewer_idle_floor
  def reviewer_idle_timeout(:infinity), do: :infinity
  def reviewer_idle_timeout(idle) when is_integer(idle), do: max(idle, @reviewer_idle_floor)

  # First pass gets the full gate prompt; a Task-203 re-prompt (count > 0) gets
  # the terse "harness couldn't read your verdict — write a valid one now" nudge.
  @doc false
  @spec reviewer_invocation_prompt(data()) :: String.t()
  def reviewer_invocation_prompt(%{reviewer_reprompt_count: count} = data) when count > 0, do: reviewer_reprompt(data)

  def reviewer_invocation_prompt(data), do: reviewer_prompt(data)

  # Task 203 re-prompt (generalized): a fresh invocation of the same reviewer
  # whose prior pass left no READABLE verdict — it either exited without writing
  # the artifact or wrote invalid JSON. All review work is already committed in
  # this worktree; the ONE remaining job is producing a valid artifact. Terse by
  # design — the verdict schema + the task framing the agent needs to ground an
  # honest approve/reject, nothing more.
  @doc false
  @spec reviewer_reprompt(data()) :: String.t()
  def reviewer_reprompt(data) do
    """
    You are the cross-family reviewer for a harness run. You already reviewed this work in a prior
    pass, but harness could not read a valid verdict from `#{Review.artifact_path()}` — it was missing
    or contained invalid JSON, so harness is about to discard the entire run.

    This is your ONLY remaining job, nothing else: all prior fixes are already committed in this
    worktree — assess its current state, run the project's checks below, then write a VALID verdict
    file NOW and stop. Do not re-do a full review or make new changes unless a check is actually
    failing.

    You MUST run the project's checks. If checks are still red after your fixes and you choose to
    dismiss that red as environmental or out-of-scope, first reproduce the benign cause and record
    that reproduced cause in `checks` and `concerns` (command, failing output, and mechanism). If you
    cannot reproduce a benign cause, treat the red as a real defect.

    Verdict artifact — write this, then stop:

    #{Review.artifact_path()}
    {
      "verdict": "approve" | "reject",
      "report": "<what you found, what you fixed, why you decided>",
      "checks": {"<command you ran>": {"passed": true | false, "output": "<short relevant output>", "mechanism": "<why a red is benign, if dismissed>"}},
      "concerns": [],
      "facets": {"language": "...", "surface": "...", "archetype": "...", "difficulty": "...", "risk": "..."},
      "skills": {"<domain or quality the diff exercised>": {"score": <0-10>, "note": "<one line>"}}
    }

    `checks` records the actual command(s) you ran and your own boolean pass/fail call for each.
    `concerns` is a list of caveats you are explicitly approving with; leave it [] only when there
    are none. A dismissed red is never a bare prose aside.

    `facets` characterizes what this task ACTUALLY was, read from the spec + the real diff (open
    vocabulary). `skills` scores ONLY the domains and qualities the diff genuinely exercised (otp,
    ecto, concurrency, error_handling, idiom, test_rigor, security, docs, truthfulness, ...) — each a
    {"score": 0-10, "note": "..."} map, open vocabulary, no padding with zeros.

    Fixing is cheaper than rejecting — approve anything salvageable; reject only if nothing is.
    A missing or malformed #{Review.artifact_path()} fails this run for good.

    Project check hint (run these yourself; judge the output):
    #{Text.placeholder(data.project.check_command)}

    Implementer: #{data.item.agent}
    Current commit: #{current_sha(data)}

    Task spec:
    #{Text.placeholder(task_text(data))}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}
    """
  end

  # The reviewer's instructions — THE gate's prompt. The judgment (is the work
  # good, do the checks pass in a way that matters, what does an empty diff
  # mean) lives entirely in the reviewer agent; harness only frames it and
  # reads the artifact it writes.
  @doc false
  @spec reviewer_prompt(data()) :: String.t()
  def reviewer_prompt(data) do
    """
    You are the cross-family reviewer for a harness run — THE gate that decides whether this work is accepted.

    #{reviewer_situation(data)}

    Your job, in order:
    1. Review the work against the task spec and acceptance criteria below.
    2. You MUST run the project's checks yourself (hint below) and judge the results.
    3. Fix everything that needs fixing — your own edits, your own commits. Wrong approach, bugs,
       missing tests, failing checks, style: fix it all, then approve.
    4. LAST, after every fix and check is done: write your verdict to `#{Review.artifact_path()}`
       (format below). This is your FINAL action — write the file, then stop.

    If checks are still red after your fixes and you choose to dismiss that red as environmental or
    out-of-scope, first reproduce the benign cause and record that reproduced cause in `checks` and
    `concerns` (command, failing output, and mechanism). If you cannot reproduce a benign cause,
    treat the red as a real defect. A dismissed red is never a bare prose aside.

    ⚠️ Writing `#{Review.artifact_path()}` is mandatory and unconditional — it is the ONE thing
    harness reads. If you finish fixing and reviewing but exit WITHOUT writing it, your entire run is
    discarded as a failure and the work is thrown away, no matter how much you fixed. Do not end your
    turn, declare yourself done, or go idle until the file is written. Even when you reject, even when
    you ran out of other things to do — the verdict file is always the last thing you write before you
    stop. Prose in your transcript has no effect; only this file does.

    Fixing is always cheaper than rejecting — a rejection costs two more full agent runs.
    Anything you can fix: fix it and approve. Reject ONLY if there is literally nothing to salvage
    (an empty or unusable worktree, or work so destructive or off-task that redoing it from scratch
    is faster than fixing it).

    Never change the current task's roadmap state. Do not mark this task done, verified, shipped,
    pending, or blocked — harness writes the outcome back (`done` + `verified` + `shipped_in`) after
    you approve and the work lands. If the implementer left a roadmap edit (e.g. a `status = "done"`
    flip or a hand-edited `ROADMAP.md`), revert it as part of your fixes — it is corruption, not
    deliverable.

    Discovery filing: if you surface genuine follow-up work while gating and choose NOT to fix it
    inline, file it as a real rmap task in this worktree instead of only mentioning it in prose.
    Use `rmap new --from-stdin --roadmap-path #{inspect(data.project.roadmap_path)}` and provide a
    TOML `[[task]]` fragment. You decide what counts as a discovery; harness does not classify,
    rank, score, or read back the filed task. In your verdict report, name the filed task id(s).

    Verdict artifact — REQUIRED final action, write it even when you reject:

    #{Review.artifact_path()}
    {
      "verdict": "approve" | "reject",
      "report": "<what you found, what you fixed, why you decided>",
      "checks": {
        "<command you ran>": {
          "passed": true | false,
          "output": "<short relevant output>",
          "mechanism": "<why a red is benign, if dismissed>"
        }
      },
      "concerns": [],
      "facets": {
        "language": "<elixir | rust | js | ...>",
        "surface": "<otp | ecto | phoenix | liveview | cli | migration | docs | ...>",
        "archetype": "<feature | bugfix | refactor | test | infra | ...>",
        "difficulty": "<trivial | moderate | hard>",
        "risk": "<low | medium | high>"
      },
      "skills": {
        "<domain or quality the diff actually exercised>": {"score": <0-10>, "note": "<one line>"}
      }
    }

    `facets` is GROUND TRUTH — characterize what this task ACTUALLY was from the task spec and the
    REAL diff in front of you, not from any label it was filed under. Open vocabulary: add/rename keys
    as the work warrants; the five above are a starting set, not a fixed schema.

    `skills` is a two-axis rubric. Score ONLY the skills this diff genuinely exercised — leave the rest
    out, never pad with zeros:
    - programming domains touched — e.g. otp, ecto, phoenix, liveview, js, rust
    - cross-cutting qualities shown — e.g. concurrency, error_handling, idiom, test_rigor, security,
      docs, truthfulness (the implementer's self-report vs what you actually found)
    Each is a {"score": 0-10, "note": "..."} map; the note is your one-line evidence for the score.
    Open vocabulary — these are examples, not an enum.

    `checks` records the actual command(s) you ran and your own boolean pass/fail call for each.
    `concerns` is a list of caveats you are explicitly approving with; leave it [] only when there
    are none. If you approve with a dismissed red, the reproduced mechanism belongs here, not only in
    the report.

    A missing or malformed #{Review.artifact_path()} fails this run.

    Project check hint (run these yourself; judge the output):
    #{Text.placeholder(data.project.check_command)}

    Implementer: #{data.item.agent}
    Current commit: #{current_sha(data)}

    Task spec:
    #{Text.placeholder(task_text(data))}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}

    Implementer transcript tail:
    #{Text.placeholder(transcript_tail(data.transcript))}

    Diff stat:
    #{Text.placeholder(diff_stat(data))}
    """
  end

  # The one piece of situational framing the reviewer needs: whether the
  # implementer actually committed anything. What an empty diff MEANS is the
  # reviewer's judgment, not a harness disposition branch.
  @doc false
  @spec reviewer_situation(data()) :: String.t()
  def reviewer_situation(%{implementer_empty_diff?: true}) do
    String.trim_trailing("""
    The implementer produced NO diff in this worktree. The transcript tail below shows what it
    did — it may have hit a usage limit, crashed, or believed the work was already done. Decide
    what the empty diff means:
    - Already implemented / you can implement it: do the work or verify it, run the checks, approve.
    - Nothing happened and nothing is salvageable: reject, and say why in your report.
    """)
  end

  def reviewer_situation(_data) do
    String.trim_trailing("""
    The implementer has committed work in this SAME worktree. It is yours to review, fix, and gate.
    """)
  end

  @doc false
  @spec transcript_tail(String.t()) :: String.t()
  def transcript_tail(transcript) when byte_size(transcript) <= @reviewer_transcript_tail_bytes, do: transcript

  def transcript_tail(transcript) do
    tail =
      binary_part(
        transcript,
        byte_size(transcript) - @reviewer_transcript_tail_bytes,
        @reviewer_transcript_tail_bytes
      )

    Text.valid_utf8_tail(tail)
  end

  @doc false
  @spec diff_stat(data()) :: String.t()
  def diff_stat(data) do
    case Git.run(["diff", "--stat", "#{data.worktree.base_sha}..HEAD"], data.worktree.path) do
      {:ok, stat} -> String.trim(stat)
      {:error, reason} -> "diff stat unavailable: #{inspect(reason)}"
    end
  end

  @doc false
  @spec reviewer_commit_message(data()) :: String.t()
  def reviewer_commit_message(data) do
    "harness: reviewer fixes — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  # ── In-run discernment (sampled live-transcript review) ──────────────────
  #
  # A cross-family grader samples the implementer's partial transcript while it
  # works and can halt a high-confidence rogue/destructive/spinning attempt.
  # The halted attempt routes through the normal pipeline (commit → review);
  # there is no procedural re-dispatch loop.

  @doc false
  @spec grade_discernment(data()) :: {:ok, AuditReview.result()} | {:error, term()}
  def grade_discernment(data) do
    opts = data.in_run_discernment

    with {:ok, grader} <- discernment_grader(data),
         true <- discernment_grader_dispatchable?(grader) || {:error, {:discernment_grader_unavailable, grader}},
         {:ok, evidence} <- discernment_evidence(data) do
      [
        implementer: data.item.agent,
        sha: current_sha(data),
        prompt: discernment_prompt(data, evidence),
        cwd: data.worktree.path
      ]
      |> put_opt(:grader, grader)
      |> put_opt(:model, Keyword.get(opts, :model))
      |> put_opt(:adapter_opts, Keyword.get(opts, :adapter_opts))
      |> put_opt(:total_timeout, Keyword.get(opts, :total_timeout))
      |> put_opt(:idle_timeout, Keyword.get(opts, :idle_timeout))
      |> AuditReview.grade_fix()
    end
  end

  @doc false
  @spec discernment_evidence(data()) :: {:ok, String.t()} | {:error, term()}
  def discernment_evidence(data) do
    case Git.run(["diff", "--stat", "--patch", "--find-renames", "--no-ext-diff"], data.worktree.path) do
      {:ok, diff} -> {:ok, truncate_semantic_diff(diff)}
      {:error, reason} -> {:error, {:diff_unavailable, reason}}
    end
  end

  @doc false
  @spec discernment_grader(data()) :: {:ok, atom()} | {:error, term()}
  def discernment_grader(data) do
    discernment_grader(data.item.agent, Keyword.get(data.in_run_discernment, :grader))
  end

  @doc false
  @spec discernment_grader(atom(), term()) :: {:ok, atom()} | {:error, term()}
  def discernment_grader(implementer, nil), do: AuditReview.default_grader(implementer)

  def discernment_grader(implementer, grader) when is_atom(grader) do
    case known_grader_agent(grader) do
      {:ok, ^implementer} -> AuditReview.default_grader(implementer)
      _other -> {:ok, grader}
    end
  end

  def discernment_grader(_implementer, grader), do: {:error, {:invalid_option, :grader, grader}}

  @doc false
  @spec discernment_grader_dispatchable?(atom()) :: boolean()
  def discernment_grader_dispatchable?(grader) when is_atom(grader) do
    case known_grader_agent(grader) do
      {:ok, agent} ->
        case AgentRegistry.module_for_agent(agent) do
          {:ok, module} -> AgentSettings.enabled?(agent) and AgentRegistry.available?(module)
          {:error, _reason} -> false
        end

      :unknown ->
        AgentRegistry.available?(grader)
    end
  end

  @doc false
  @spec known_grader_agent(atom()) :: {:ok, atom()} | :unknown
  def known_grader_agent(grader) do
    case AgentRegistry.module_for_agent(grader) do
      {:ok, _module} ->
        {:ok, grader}

      {:error, _reason} ->
        case AgentRegistry.agent_for_module(grader) do
          {:ok, agent} -> {:ok, agent}
          {:error, _reason} -> :unknown
        end
    end
  end

  @doc false
  @spec handle_in_run_discernment_outcome(data(), AuditReview.verdict(), Outcome.t()) :: handler_result()
  def handle_in_run_discernment_outcome(data, :unclear, %Outcome{kind: kind})
      when kind in [{:timed_out, :idle}, {:timed_out, :total}] do
    reason = {:grader_failed, kind}
    feedback = discernment_failure_feedback(reason)
    notify_in_run_discernment(data, :notify_only, feedback, reason)
    {:keep_state, data}
  end

  def handle_in_run_discernment_outcome(data, verdict, %Outcome{} = outcome) do
    feedback = %{
      verdict: verdict,
      rationale: discernment_rationale(outcome.output)
    }

    handle_in_run_discernment_verdict(data, verdict, feedback)
  end

  @doc false
  @spec handle_in_run_discernment_verdict(
          data(),
          AuditReview.verdict(),
          %{verdict: AuditReview.verdict(), rationale: String.t()}
        ) :: handler_result()
  def handle_in_run_discernment_verdict(data, :reject, feedback) do
    # High-confidence rogue/destructive/spinning behavior: halt the implementer
    # and route whatever it left through the normal pipeline — commit, then let
    # the cross-family reviewer judge the worktree. Never a procedural
    # re-dispatch.
    feedback = Map.put(feedback, :trigger, :in_run)
    notify_in_run_discernment(data, :halt, feedback)
    terminate_agent(data)
    cancel_task(data.task)

    {:next_state, :committing, %{data | task: nil, agent_run: nil, cancel_requested: nil}}
  end

  def handle_in_run_discernment_verdict(data, verdict, feedback) do
    notify_in_run_discernment(data, :notify_only, %{feedback | verdict: verdict})
    {:keep_state, data}
  end

  # The grader could not run (spawn failure, crash, timeout). In-run discernment
  # is advisory: an infrastructure failure is reported, never acted on.
  @doc false
  @spec discernment_failure_feedback(term()) :: %{verdict: AuditReview.verdict(), rationale: String.t()}
  def discernment_failure_feedback(reason) do
    %{verdict: :unclear, rationale: "In-run discernment grader did not run: #{inspect(reason)}"}
  end

  @doc false
  @spec notify_in_run_discernment(
          data(),
          :notify_only | :halt,
          %{
            required(:verdict) => AuditReview.verdict(),
            required(:rationale) => String.t(),
            optional(:trigger) => atom()
          },
          term() | nil
        ) :: :ok
  def notify_in_run_discernment(data, action, feedback, reason \\ nil) do
    outcome =
      maybe_put_reason(
        %{
          action: action,
          verdict: feedback.verdict,
          rationale: feedback.rationale,
          transcript_seq: data.transcript_seq
        },
        reason
      )

    Notification.notify(%NotificationEvent{
      type: :in_run_discernment,
      task_id: to_string(data.item.id),
      run_id: data.run_id,
      project: data.project.name,
      branch: "harness/" <> data.run_id,
      land_attempt: data.land_attempt,
      outcome: outcome
    })
  end

  @doc false
  @spec maybe_put_reason(map(), term() | nil) :: map()
  def maybe_put_reason(outcome, nil), do: outcome
  def maybe_put_reason(outcome, reason), do: Map.put(outcome, :reason, reason)

  @doc false
  @spec discernment_prompt(data(), String.t()) :: String.t()
  def discernment_prompt(data, diff) do
    """
    You are the sampled cross-family semantic discernment reviewer for an in-flight harness run.

    You are reading a PARTIAL live transcript. Agents often read and explore
    before editing, so do not punish uncertainty, quiet exploration, or an
    incomplete solution. Ambiguous or low-confidence concerns must be REPORTED
    in your rationale without a reject sentinel. Emit REJECT only for
    high-confidence rogue/destructive/out-of-scope behavior or productive spin
    that should halt this attempt and re-dispatch with correction.

    Your verdict is demote-only. APPROVE does not bless the run or accept the
    work; it only means "no intervention from this sample."

    Implementer: #{data.item.agent}
    Current commit: #{current_sha(data)}

    Task body:
    #{Text.placeholder(data.item.body)}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}

    Partial live transcript:
    #{Text.placeholder(truncate_semantic_diff(data.transcript))}

    Current uncommitted diff, if any:
    #{Text.placeholder(diff)}

    Return one concise rationale line, then a final sentinel on its own line
    only when confident:
    <<<VERDICT:APPROVE>>>
    or
    <<<VERDICT:REJECT>>>
    """
  end

  @doc false
  @spec truncate_semantic_diff(String.t()) :: String.t()
  def truncate_semantic_diff(diff) when byte_size(diff) <= @semantic_diff_max_bytes, do: diff

  def truncate_semantic_diff(diff) do
    head = binary_part(diff, 0, @semantic_diff_max_bytes)

    "[harness: showing the first #{@semantic_diff_max_bytes} of #{byte_size(diff)} bytes]\n" <>
      Text.valid_utf8_head(head)
  end

  @doc false
  @spec format_acceptance_criteria([String.t()]) :: String.t()
  def format_acceptance_criteria([]), do: "(none)"

  def format_acceptance_criteria(criteria), do: Enum.map_join(criteria, "\n", fn criterion -> "- #{criterion}" end)

  @doc false
  @spec discernment_rationale(String.t()) :: String.t()
  def discernment_rationale(output) when is_binary(output) do
    rationale =
      output
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "<<<VERDICT:"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()

    case rationale do
      nil -> "No rationale provided."
      rationale -> rationale
    end
  end

  @doc false
  @spec maybe_sample_in_run_discernment(state(), data()) :: handler_result()
  def maybe_sample_in_run_discernment(:running, data) do
    opts = data.in_run_discernment
    now = System.monotonic_time(:millisecond)

    if in_run_discernment_due?(data, opts, now) do
      task = start_task(fn -> grade_discernment(data) end)
      {:keep_state, %{data | discernment_task: task, last_discernment_sample_ms: now}}
    else
      {:keep_state, data}
    end
  end

  def maybe_sample_in_run_discernment(_state, data), do: {:keep_state, data}

  @doc false
  @spec in_run_discernment_due?(data(), keyword(), integer()) :: boolean()
  def in_run_discernment_due?(data, opts, now) do
    in_run_discernment_enabled?(opts) and
      is_nil(data.discernment_task) and
      data.transcript_bytes >= Keyword.get(opts, :min_transcript_bytes, @default_discernment_min_transcript_bytes) and
      sample_interval_due?(data.last_discernment_sample_ms, Keyword.get(opts, :sample_interval_ms), now) and
      discernment_weight_passes?(data, opts, now)
  end

  @doc false
  @spec in_run_discernment_enabled?(keyword()) :: boolean()
  def in_run_discernment_enabled?(opts), do: Keyword.get(opts, :enabled, false) == true

  @doc false
  @spec sample_interval_due?(integer() | nil, non_neg_integer() | nil, integer()) :: boolean()
  def sample_interval_due?(nil, _interval, _now), do: true

  def sample_interval_due?(last, nil, now), do: now - last >= @default_discernment_sample_interval_ms

  def sample_interval_due?(last, interval, now), do: now - last >= interval

  # Public only as a deterministic test seam for the stakes gate (it reads the
  # structured d-score / :security / :bug markers off the Item, not prose) — an
  # internal predicate of the running-state lifecycle, never a consumer surface.
  @doc false
  @spec discernment_weight_passes?(data(), keyword(), integer()) :: boolean()
  def discernment_weight_passes?(data, opts, now) do
    min_weight = Keyword.get(opts, :min_weight, @default_discernment_min_weight)

    explicit_weight = Keyword.get(opts, :weight)

    cond do
      is_integer(explicit_weight) ->
        explicit_weight >= min_weight

      task_d_score(data) >= min_weight ->
        true

      high_stakes_marker?(data) ->
        true

      long_running?(data, opts, now) ->
        true

      true ->
        false
    end
  end

  # rmap's typed difficulty score, threaded onto the Item at ingest. No score
  # (historical ingests, scoreless tasks) reads as 0 — never triggers on weight.
  @doc false
  @spec task_d_score(data()) :: non_neg_integer()
  def task_d_score(%{item: %Item{d: d}}) when is_integer(d), do: d
  def task_d_score(_data), do: 0

  # The typed `:security` / `:bug` markers from rmap, not a prose keyword scrape:
  # catches a :security-tagged task whose prose never says "security", and does
  # not false-positive on a body that merely mentions "fixed a bug".
  @doc false
  @spec high_stakes_marker?(data()) :: boolean()
  def high_stakes_marker?(%{item: %Item{markers: markers}}), do: :security in markers or :bug in markers

  @doc false
  @spec long_running?(data(), keyword(), integer()) :: boolean()
  def long_running?(data, opts, now) do
    long_running_ms = Keyword.get(opts, :long_running_ms, @default_discernment_long_running_ms)
    now - data.started_at_ms >= long_running_ms
  end

  @doc false
  @spec task_text(data()) :: String.t()
  def task_text(data) do
    [
      data.item.title,
      data.item.prompt,
      data.item.body,
      Enum.join(data.item.acceptance_criteria, "\n")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Resolves the in-run discernment options once at init: the per-run
  # `:in_run_discernment` opt overlays the `:harness, :in_run_discernment`
  # application config. Disabled unless `enabled: true` is present.
  @doc false
  @spec in_run_discernment_opts(keyword()) :: keyword()
  def in_run_discernment_opts(opts) do
    global =
      :harness
      |> Application.get_env(:in_run_discernment, [])
      |> normalize_opts()

    local =
      opts
      |> Keyword.get(:in_run_discernment, [])
      |> normalize_opts()

    Keyword.merge(global, local)
  end

  @doc false
  @spec current_sha(data()) :: String.t()
  def current_sha(%{worktree: %Worktree{path: path, base_sha: fallback}}) do
    case Git.run(["rev-parse", "HEAD"], path) do
      {:ok, sha} -> non_empty_sha(String.trim(sha), fallback)
      {:error, _reason} -> fallback
    end
  end

  @doc false
  @spec non_empty_sha(String.t(), String.t()) :: String.t()
  def non_empty_sha("", fallback), do: fallback
  def non_empty_sha(sha, _fallback), do: sha

  # The message stamped on the agent's delivery commit — identifies the run and
  # the rmap task it served, so the commit is legible in `git log` after the
  # worktree it came from is gone.
  @doc false
  @spec commit_message(data()) :: String.t()
  def commit_message(data) do
    "harness: agent delivery — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  @doc false
  @spec worktree_opts(data()) :: keyword()
  # An explicit :base_ref (e.g. a resumed run branching off the retained
  # harness/<old-run-id> branch) wins over the computed origin/<target> base.
  def worktree_opts(%{base_ref: base_ref} = data) when is_binary(base_ref) and base_ref != "" do
    Keyword.put(base_worktree_opts(data), :base_ref, base_ref)
  end

  def worktree_opts(%{project: %Project{target_branch: target}} = data) when is_binary(target) and target != "" do
    opts = base_worktree_opts(data)

    case fetch_target(data.project, target, data.substrate_retry) do
      :ok ->
        Keyword.put(opts, :base_ref, "origin/" <> target)

      {:error, reason} ->
        Logger.warning(
          "harness run: failed to fetch origin/#{target} for run #{data.run_id}: #{inspect(reason)}; falling back to HEAD"
        )

        opts
    end
  end

  def worktree_opts(data) do
    base_worktree_opts(data)
  end

  @doc false
  @spec base_worktree_opts(data()) :: keyword()
  def base_worktree_opts(data) do
    put_opt([id: data.run_id, substrate_retry: data.substrate_retry], :base_dir, data.base_dir)
  end

  @doc false
  @spec fetch_target(Project.t(), String.t(), keyword()) :: :ok | {:error, Git.error()}
  def fetch_target(%Project{} = project, target, substrate_retry) do
    case retry_substrate(substrate_retry, fn -> Git.run(["fetch", "origin", target], Project.repo_path(project)) end) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec run_driver(data(), module(), Invocation.t(), keyword()) :: {:ok, Outcome.t()} | {:error, term()}
  def run_driver(data, adapter, %Invocation{} = invocation, opts) do
    retry_substrate(data.substrate_retry, fn -> Driver.run(adapter, invocation, opts) end)
  end

  @doc false
  @spec retry_substrate(keyword(), (-> term())) :: term()
  def retry_substrate(opts, fun) when is_function(fun, 0) do
    RetryPolicy.retry(fun, RetryPolicy.new(opts))
  end

  @doc false
  @spec driver_opts(data(), pid()) :: keyword()
  def driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:run_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, implementer_idle_timeout(data.idle_timeout))
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  @doc false
  @spec commit_worktree(data(), Worktree.t(), String.t()) ::
          {:ok, :committed | :no_changes, non_neg_integer()} | {:error, Worktree.error()}
  def commit_worktree(data, %Worktree{} = worktree, message) do
    retry_substrate(data.substrate_retry, fn ->
      with {:ok, diff_size} <- Worktree.diff_size(worktree),
           {:ok, status} <- Worktree.commit(worktree, message, substrate_retry: [max_retries: 0]) do
        {:ok, status, diff_size}
      end
    end)
  end

  @doc false
  @spec put_opt(keyword(), atom(), term()) :: keyword()
  def put_opt(opts, _key, nil), do: opts
  def put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc false
  @spec normalize_opts(nil | keyword() | map()) :: keyword()
  def normalize_opts(nil), do: []
  def normalize_opts(opts) when is_list(opts), do: opts
  def normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)

  @doc false
  @spec checkout_snapshot_for_run(data()) :: String.t() | nil
  def checkout_snapshot_for_run(%{checkout_pollution_check?: true} = data) do
    checkout_snapshot(Project.repo_path(data.project))
  end

  def checkout_snapshot_for_run(data) do
    if AgentAdapter.supports?(data.adapter, :worktree_isolation) do
      nil
    else
      checkout_snapshot(Project.repo_path(data.project))
    end
  end

  @doc false
  @spec checkout_snapshot(String.t()) :: String.t() | nil
  def checkout_snapshot(repo) when is_binary(repo) do
    case Isolation.snapshot(repo) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        Logger.warning("harness run: checkout snapshot failed for #{repo}: #{inspect(reason)}")
        nil
    end
  end

  @doc false
  @spec checkout_pollution_reason(data()) :: Result.reason() | nil
  def checkout_pollution_reason(data) do
    opts = [pollution_allowlist: data.pollution_allowlist]

    case Isolation.check_pollution(Project.repo_path(data.project), data.checkout_snapshot, opts) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  @doc false
  @spec worktree_isolation_limitation(module()) :: String.t() | nil
  def worktree_isolation_limitation(adapter) do
    if function_exported?(adapter, :worktree_isolation_limitation, 0) do
      adapter.worktree_isolation_limitation()
    end
  end

  @doc false
  @spec resolve_pollution_allowlist(Project.t(), keyword()) :: [String.t()]
  def resolve_pollution_allowlist(project, opts) do
    case Keyword.get(opts, :pollution_allowlist) do
      allowlist when is_list(allowlist) ->
        allowlist

      _ ->
        case project do
          %Project{pollution_allowlist: allowlist} when is_list(allowlist) -> allowlist
          _ -> Isolation.pollution_allowlist([])
        end
    end
  end

  @doc false
  @spec configured(atom(), term()) :: term()
  def configured(key, default) do
    :harness |> Application.get_env(:run, []) |> Keyword.get(key, default)
  end

  # Resolves a run timeout: explicit opt wins, else the `Harness.Config` schema
  # value (schema default folded with any persisted operator override). Keeps the
  # `||` fallbacks out of `init/1` so it stays under the complexity gate, and
  # routes the read through the schema (Task 167) — defaults live in `Config`, not
  # in `@default_*` attributes here.
  @doc false
  @spec run_timeout(keyword(), atom()) :: timeout() | nil
  def run_timeout(opts, key) do
    Keyword.get(opts, key) || Config.get({:run, key})
  end

  @doc false
  @spec requested_model(keyword(), Item.t(), module()) :: String.t() | nil
  def requested_model(opts, item, adapter) do
    if Keyword.has_key?(opts, :requested_model) do
      Keyword.fetch!(opts, :requested_model)
    else
      item.model || configured_model(adapter, item.agent)
    end
  end

  @doc false
  @spec configured_model(module(), atom()) :: String.t() | nil
  def configured_model(adapter, agent) do
    if adapter.capabilities().model_families == [], do: nil, else: Config.agent_model(agent)
  end

  # Resolves the per-run memory watchdog ceiling + sample interval (Task 200):
  # explicit opt > app env > module default. Kept out of `init/1`'s data map so
  # the `||` fallbacks don't push init over the cyclomatic-complexity gate.
  @doc false
  @spec mem_watchdog_config(keyword()) :: {pos_integer(), pos_integer()}
  def mem_watchdog_config(opts) do
    {Keyword.get(opts, :mem_threshold_kb) || configured(:mem_threshold_kb, @default_mem_threshold_kb),
     Keyword.get(opts, :mem_sample_interval) || configured(:mem_sample_interval, @default_mem_sample_interval)}
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
