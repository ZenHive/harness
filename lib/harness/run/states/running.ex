defmodule Harness.Run.States.Running do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4, settle_implementer_outcome: 2]
  import Harness.Run.Actions.Control, only: [cancel_task: 1, do_cancel: 3, do_hold: 2, fail: 2, terminate_agent: 1]

  import Harness.Run.Actions.Discernment,
    only: [discernment_failure_feedback: 1, handle_in_run_discernment_outcome: 3, notify_in_run_discernment: 4]

  import Harness.Run.Actions.Recovery, only: [recover_checkout_pollution: 2]
  import Harness.Run.Actions.Timeouts, only: [running_idle_timeout: 1]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2, start_task: 1, status_snapshot: 2]

  import Harness.Run.Actions.Worktree,
    only: [
      build_invocation: 1,
      checkout_pollution_reason: 1,
      checkout_snapshot_for_run: 1,
      driver_opts: 2,
      run_driver: 4,
      tag_composed_input: 2
    ]

  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript

  require Logger

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  # ── State: running — the implementer agent works in the worktree ──────────

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  # Entering `running` always means a fresh agent is about to spawn — the first
  # dispatch, or an operator-steered resume. `agent_run` / `agent_outcome` are
  # reset so a stale handle from a prior attempt never misleads the cancel-defer
  # logic or a `status/1` snapshot.
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:running, data)
    RunFeed.broadcast_update(status_snapshot(:running, data))
    parent = self()
    invocation = build_invocation(data)
    checkout_snapshot = checkout_snapshot_for_run(data)
    task = start_task(fn -> run_driver(data, data.adapter, invocation, driver_opts(data, parent)) end)

    {:keep_state,
     %{
       data
       | task: task,
         checkout_snapshot: checkout_snapshot,
         agent_run: nil,
         agent_outcome: nil
     }}
  end

  def handle(:info, {:run_handle, %AgentRun{} = run}, data) do
    data = %{
      data
      | agent_run: run,
        composed_inputs: data.composed_inputs ++ [tag_composed_input(run, data)]
    }

    cond do
      data.hold_requested == :interrupt ->
        do_hold(data, :interrupt)

      is_tuple(data.cancel_requested) ->
        {reason, from} = data.cancel_requested
        do_cancel(data, reason, from)

      true ->
        {:keep_state, data, [{:state_timeout, running_idle_timeout(data), :implementer_idle_timeout}]}
    end
  end

  def handle(:state_timeout, :implementer_idle_timeout, %{agent_run: %AgentRun{} = run} = data) do
    terminate_agent(data)
    cancel_task(data.task)
    cancel_task(data.discernment_task)

    outcome = %Outcome{
      run: run,
      output: Transcript.to_binary(data.transcript),
      exit_status: nil,
      kind: {:timed_out, :idle}
    }

    settle_implementer_outcome(%{data | task: nil, discernment_task: nil}, outcome)
  end

  def handle(:state_timeout, :implementer_idle_timeout, _data), do: :keep_state_and_data

  def handle(
        :info,
        {ref, {:ok, %{verdict: verdict, outcome: %Outcome{} = outcome}}},
        %{discernment_task: %Task{ref: ref}} = data
      ) do
    Process.demonitor(ref, [:flush])

    handle_in_run_discernment_outcome(%{data | discernment_task: nil}, verdict, outcome)
  end

  def handle(:info, {ref, {:error, reason}}, %{discernment_task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    Logger.warning("harness run: in-run discernment grader failed for #{data.run_id}: #{inspect(reason)}")

    feedback = discernment_failure_feedback({:grader_failed, reason})
    notify_in_run_discernment(data, :notify_only, feedback, {:grader_failed, reason})
    {:keep_state, %{data | discernment_task: nil}}
  end

  def handle(:info, {:DOWN, ref, :process, _pid, reason}, %{discernment_task: %Task{ref: ref}} = data)
      when reason != :normal do
    Logger.warning("harness run: in-run discernment grader crashed for #{data.run_id}: #{inspect(reason)}")

    feedback = discernment_failure_feedback({:crashed, reason})
    notify_in_run_discernment(data, :notify_only, feedback, {:grader_failed, {:crashed, reason}})
    {:keep_state, %{data | discernment_task: nil}}
  end

  def handle(:info, {ref, {:ok, %Outcome{} = outcome}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    cancel_task(data.discernment_task)

    settle_implementer_outcome(%{data | task: nil, discernment_task: nil}, outcome)
  end

  def handle(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    cancel_task(data.discernment_task)
    fail(%{data | task: nil, discernment_task: nil}, {:agent_spawn_failed, reason})
  end

  def handle(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    cancel_task(data.discernment_task)
    data = %{data | task: nil, discernment_task: nil}

    case checkout_pollution_reason(data) do
      nil -> fail(data, {:driver_crashed, reason})
      pollution_reason -> recover_checkout_pollution(data, pollution_reason)
    end
  end

  def handle(event_type, event_content, data) do
    handle_common(event_type, event_content, :running, data)
  end
end
