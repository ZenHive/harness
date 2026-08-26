defmodule Harness.Run.Actions.Control do
  @moduledoc false

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.Run.MemoryGuard
  alias Harness.Run.Result

  @type data :: map()
  @type handler_result :: term()
  # Aborts an in-flight run: kills the current step task, quiesces the agent's
  # process tree if one is running, and settles `failed`. `from` is the caller
  # awaiting a cancel reply, or `nil` for a timeout-triggered abort.
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
    # Terminate-then-cancel: the adapter quiesces the captured process tree while
    # its Port is still open, before cancel_task tears down the Port owner (Task 201).
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
  # `agent_run: nil` there is nothing to terminate directly — killing the driver
  # task closes its port and a just-spawned OS process whose pid we never
  # received may leak. The boot-time `Harness.Worktree.Sweeper` reaps its
  # working directory across restarts. A deferred cancel caller (a real
  # `cancel/1` that arrived before the agent handle) still gets `:ok`.
  @doc false
  @spec force_settle_lifetime(data()) :: handler_result()
  def force_settle_lifetime(data) do
    # Terminate-then-cancel (Task 201): quiesce the captured process tree before
    # the Port owner is torn down.
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
  # running with nothing left to idle-time it out — so terminate its tree here.
  # A crashed step must never orphan an agent (and its API quota).
  # `terminate_agent/1` is a no-op when no agent spawned and idempotent when it
  # already exited.
  @doc false
  @spec fail(data(), Result.reason()) :: handler_result()
  def fail(data, reason) do
    # Terminate-then-cancel (Task 201): quiesce the captured process tree before
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

  # Force-kills the runaway process tree BEFORE the adapter teardown closes its
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
end
