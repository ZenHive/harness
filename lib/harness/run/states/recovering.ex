defmodule Harness.Run.States.Recovering do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4]
  import Harness.Run.Actions.Control, only: [terminate_recovery: 1]

  import Harness.Run.Actions.Recovery,
    only: [clear_recovery_run: 1, fail_recovery_dead: 2, run_recovery: 2, settle_recovery: 2]

  import Harness.Run.Actions.Reviewing, only: [select_reviewers: 1]
  import Harness.Run.Actions.Settlement, only: [accumulate_recovery_token_usage: 2]
  import Harness.Run.Actions.Timeouts, only: [reviewing_idle_timeout: 1]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2, start_task: 1, status_snapshot: 2]

  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.Dashboard.RunFeed

  require Logger

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  # ── State: recovering — bounded AI seam before checkout-pollution failure ──

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:recovering, data)
    RunFeed.broadcast_update(status_snapshot(:recovering, data))

    # Task 228 renamed select_reviewer/1 -> select_reviewers/1 ({:ok, [module, ...]}
    # rotation slate). The recovery seam is a one-shot AI call, so it takes the
    # primary (highest-priority cross-family) adapter and ignores the rotation tail.
    case select_reviewers(data) do
      {:ok, [adapter | _candidates]} ->
        parent = self()
        task = start_task(fn -> run_recovery(%{data | recovery_adapter: adapter}, parent) end)

        {:keep_state,
         %{
           data
           | task: task,
             recovery_adapter: adapter,
             recovery_run: nil,
             recovery_attempts: data.recovery_attempts + 1
         }, [{:state_timeout, data.reviewer_spawn_timeout, :recovery_spawn_timeout}]}

      {:error, reason} ->
        Logger.warning("harness run: recovery agent unavailable for #{data.run_id}: #{inspect(reason)}")
        {:next_state, :failed, %{data | reason: data.recovery_reason}}
    end
  end

  def handle(:info, {:recovery_handle, %AgentRun{} = run}, data) do
    {:keep_state, %{data | recovery_run: run}, [{:state_timeout, reviewing_idle_timeout(data), :recovery_idle_timeout}]}
  end

  def handle(:state_timeout, :recovery_spawn_timeout, %{recovery_run: nil} = data) do
    fail_recovery_dead(data, "Recovery agent never spawned within #{data.reviewer_spawn_timeout}ms.")
  end

  def handle(:state_timeout, :recovery_spawn_timeout, _data), do: :keep_state_and_data

  def handle(:state_timeout, :recovery_idle_timeout, data) do
    fail_recovery_dead(data, "Recovery made no progress within #{reviewing_idle_timeout(data)}ms.")
  end

  def handle(:info, {ref, {:ok, %{outcome: %Outcome{} = outcome, recovery: recovery}}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    data =
      data
      |> clear_recovery_run()
      |> Map.put(:task, nil)
      |> accumulate_recovery_token_usage(outcome)

    settle_recovery(data, recovery)
  end

  def handle(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    terminate_recovery(data)
    fail_recovery_dead(%{data | task: nil}, "Recovery failed to run: #{inspect(reason)}")
  end

  def handle(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    terminate_recovery(data)
    fail_recovery_dead(%{data | task: nil}, "Recovery crashed: #{inspect(reason)}")
  end

  def handle(event_type, event_content, data) do
    handle_common(event_type, event_content, :recovering, data)
  end
end
