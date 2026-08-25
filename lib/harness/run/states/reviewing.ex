defmodule Harness.Run.States.Reviewing do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4]
  import Harness.Run.Actions.Control, only: [terminate_reviewer: 1]

  import Harness.Run.Actions.Reviewing,
    only: [
      clear_reviewer_run: 1,
      ensure_reviewer_model_available: 1,
      rotate_or_fail_review: 2,
      run_reviewer: 2,
      settle_review: 2
    ]

  import Harness.Run.Actions.Timeouts,
    only: [reviewer_idle_timeout_report: 1, reviewer_spawn_timeout_report: 1, reviewing_idle_timeout: 1]

  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2, start_task: 1, status_snapshot: 2]

  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.Dashboard.RunFeed

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  # ── State: reviewing — the cross-family reviewer is THE gate ─────────────

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:reviewing, data)

    case ensure_reviewer_model_available(data) do
      :ok ->
        data = %{data | reviewer_attempt: data.reviewer_attempt + 1}
        RunFeed.broadcast_update(status_snapshot(:reviewing, data))
        parent = self()
        task = start_task(fn -> run_reviewer(data, parent) end)

        {:keep_state, %{data | task: task, agent_run: nil, reviewer_run: nil},
         [{:state_timeout, data.reviewer_spawn_timeout, :reviewer_spawn_timeout}]}

      {:error, reason} ->
        # A `:enter` state callback may return neither `{:next_state, …}` nor a
        # `{:next_event, …}` action (gen_statem rejects both with
        # `:bad_state_enter_action_from_state_function`). A zero-delay
        # `:state_timeout` is allowed here and fires immediately, letting the run
        # settle cleanly as `:failed` (the model-required reviewer guard is the
        # first reachable error). The state_timeout is auto-cancelled on the
        # transition out of `:reviewing`, so it never races the spawn timeout.
        {:keep_state, %{data | reason: reason}, [{:state_timeout, 0, :reviewer_model_unavailable}]}
    end
  end

  def handle(:state_timeout, :reviewer_model_unavailable, data) do
    {:next_state, :failed, data}
  end

  def handle(:info, {:reviewer_handle, %AgentRun{} = run}, data) do
    {:keep_state, %{data | reviewer_run: run}, [{:state_timeout, reviewing_idle_timeout(data), :reviewer_idle_timeout}]}
  end

  def handle(:state_timeout, :reviewer_spawn_timeout, %{reviewer_run: nil} = data) do
    rotate_or_fail_review(data, reviewer_spawn_timeout_report(data))
  end

  def handle(:state_timeout, :reviewer_spawn_timeout, _data), do: :keep_state_and_data

  def handle(:state_timeout, :reviewer_idle_timeout, data) do
    rotate_or_fail_review(data, reviewer_idle_timeout_report(data))
  end

  def handle(
        :info,
        {ref, {:ok, %{outcome: %Outcome{} = outcome, reviewer_diff_size: diff_size, review: review}}},
        %{task: %Task{ref: ref}} = data
      ) do
    Process.demonitor(ref, [:flush])
    # Capture the reviewer's settled Outcome (raw transcript + kind/exit_status)
    # — on a clean-exit-no-verdict run this is the only diagnostic of why the
    # gate produced nothing. A Task-203 re-prompt re-enters here, so the LAST
    # pass's outcome overwrites the prior (the attempt that actually settled).
    data = clear_reviewer_run(%{data | task: nil, reviewer_diff_size: diff_size, reviewer_outcome: outcome})
    settle_review(data, review)
  end

  def handle(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    terminate_reviewer(data)
    report = "Reviewer failed to run: #{inspect(reason)}"
    {:next_state, :failed, clear_reviewer_run(%{data | task: nil, reason: {:review_stuck, report}})}
  end

  def handle(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    terminate_reviewer(data)
    report = "Reviewer crashed: #{inspect(reason)}"
    {:next_state, :failed, clear_reviewer_run(%{data | task: nil, reason: {:review_stuck, report}})}
  end

  def handle(event_type, event_content, data) do
    handle_common(event_type, event_content, :reviewing, data)
  end
end
