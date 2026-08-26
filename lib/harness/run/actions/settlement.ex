defmodule Harness.Run.Actions.Settlement do
  @moduledoc false

  import Harness.Run.Actions.Reviewing, only: [maybe_capture_structured_failure: 1, reviewer_model: 1]
  import Harness.Run.Actions.Transcript, only: [agent_kind_for: 1, stamp_state_entry: 2, status_snapshot: 2]
  import Harness.Run.Actions.Worktree, only: [teardown_test_database: 1]

  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentRegistry
  alias Harness.Dashboard.RunFeed
  alias Harness.Dispatch
  alias Harness.Lander.Resilience
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.Notification
  alias Harness.Notification.Event, as: NotificationEvent
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Run.Actions.Control
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Review
  alias Harness.TokenUsage
  alias Harness.TokenUsage.GrokSession
  alias Harness.Worktree
  alias Harness.Worktree.Reaper
  alias Oban.Job

  require Logger

  @recoverable_code_reload_states [:reviewing, :recovering, :held]

  @type state :: Harness.Run.state()
  @type data :: map()

  @doc false
  @spec recoverable_code_reload_states() :: [atom()]
  def recoverable_code_reload_states, do: @recoverable_code_reload_states

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
      "task_ids" => data.item.task_ids,
      "task_fingerprints" => data.item.task_fingerprints,
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
    Control.terminate_agent(data)
    Control.terminate_recovery(data)
    Control.terminate_reviewer(data)
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
      proposed_tasks: proposed_tasks(data.review),
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
      "task_ids" => data.item.task_ids,
      "task_fingerprints" => data.item.task_fingerprints,
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
      proposed_tasks: proposed_tasks(data.review),
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

  @spec proposed_tasks(Review.t() | nil) :: [term()]
  defp proposed_tasks(%Review{proposed_tasks: proposed_tasks}), do: proposed_tasks
  defp proposed_tasks(nil), do: []

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
end
