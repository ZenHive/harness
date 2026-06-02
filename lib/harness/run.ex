defmodule Harness.Run do
  @moduledoc """
  The supervised lifecycle of one coding-agent job.

  A `Harness.Run` is a `:gen_statem` that owns one rmap task end to end: it
  creates an isolated git worktree, dispatches a headless agent into it, waits
  for the agent to terminate, runs the verification stack against the result,
  and settles on a verdict. It is the unit the project's CLAUDE.md calls "one
  run = one supervised gen_statem".

  ## States

      dispatched  — creating the isolated worktree
      running     — the agent is working in the worktree
      committing  — committing the agent's work to the run branch
      verifying   — the verification stack is grading the worktree
      reviewing   — a cross-family reviewer is fixing a red worktree inline
      held        — operator-parked; worktree retained, lifetime timer suspended
      done        — verification graded the worktree green (terminal)
      failed      — anything else (terminal)

  Each state runs its slow work in a task *monitored, never linked* by the
  gen_statem, so a crashing step surfaces as an event rather than crashing the
  run. `done` and `failed` are terminal: the run delivers a `Harness.Run.Result`
  to its subscriber as `{:harness_run, run_id, result}`, lingers briefly so a
  late `status/1` still resolves, then stops `:normal`.

  ## Grading

  A run is graded green by the verification stack alone — never by the agent's
  exit code or self-reported result. The agent's `Harness.AgentAdapter.Outcome`
  is recorded for diagnostics, but a run whose agent timed out is still
  verified: the worktree it left behind is what gets graded.

  ## Reviewer pair

  A red verdict is not necessarily terminal. While reviewer iterations remain
  (`:max_review_iterations`, default `2`), `verifying` routes to `reviewing`: a
  cross-family reviewer agent gets the worktree, the task spec, the implementer
  transcript, and the failing-check output, and fixes inline — its own edits,
  its own commits. Harness re-runs the check stack after every pass; the
  reviewer's word is never the verdict. The loop stops on green, on the
  iteration cap (settling `:failed` / `{:review_stuck, prose}`), or when no
  cross-family reviewer is available.

  Two more verdicts route through the same reviewing state (Task 162), so the
  judgment they need lives in an agent, never in harness code:

  - An **empty implementer diff** always gets a reviewer pass — the reviewer
    decides whether the task was already implemented (make the checks pass) or
    nothing happened (write a stuck-report saying why, e.g. a usage limit).
  - A **green verdict** gets one conformance-scoped reviewer pass when the
    project opts in via `review_green: true` (or a per-run `review_green:
    true` opt). Green with no reviewer available still settles `:done` —
    the check stack is the ground truth.

  ## Operator recovery (hold / steer / resume)

  `hold/1` parks a live run in `:held` so an operator can co-drive the worktree.
  Graceful hold waits for the current agent attempt to finish; `hold/2` with
  `interrupt: true` kills the agent immediately. `steer/2` stashes operator
  guidance for the next boundary; `resume/1` re-enters `:running` with a
  session-resume invocation in the same worktree. Steering requires
  `capabilities.session_resume` on the adapter.

  ## Cancellation & timeout

  `cancel/1` aborts an in-flight run; a per-run lifetime budget does the same
  when it elapses. Both kill the in-flight step task and SIGKILL the agent if
  one is running, then settle `failed`. The lifetime budget is a last-resort
  deadline — it force-settles even when the agent run handle never arrived (a
  hung adapter `build_command`/`invoke`). In that race a just-spawned OS
  process whose pid was never received may leak; the boot-time
  `Harness.Worktree.Sweeper` reaps its working directory across restarts.
  Crash isolation is structural — each run is a `:temporary` child of
  `Harness.Run.Supervisor` (a `:one_for_one` DynamicSupervisor), so one run
  crashing never touches a sibling.

  ## Observability

  `status/1` returns a `Harness.Run.Status` snapshot at any point while the run
  is in flight or lingering in a terminal state.
  """

  @behaviour :gen_statem

  use Descripex, namespace: "/run"

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.AuditReview
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Git
  alias Harness.Lander.Resilience
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Notification
  alias Harness.Notification.Event, as: NotificationEvent
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Run.Reflex
  alias Harness.Run.Result
  alias Harness.Run.Status
  alias Harness.TokenUsage
  alias Harness.TokenUsage.GrokSession
  alias Harness.Verification
  alias Harness.Verification.Check
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict
  alias Harness.Worktree
  alias Harness.Worktree.Isolation
  alias Oban.Job

  require Logger

  @registry Harness.Run.Registry
  @task_supervisor Harness.Run.TaskSupervisor

  @default_lifetime_timeout 5_400_000
  @default_terminal_linger 5_000
  @default_max_review_iterations 2
  @semantic_diff_max_bytes 80_000
  @reviewer_transcript_tail_bytes 40_000
  @default_discernment_sample_interval_ms 300_000
  @default_discernment_min_weight 6
  @default_discernment_long_running_ms 600_000
  @default_discernment_min_transcript_bytes 1
  @default_max_hold_timeout 1_800_000

  @typedoc "A lifecycle state."
  @type state ::
          :dispatched
          | :running
          | :committing
          | :verifying
          | :reviewing
          | :held
          | :done
          | :failed

  @typedoc "A run handle: a run id, or the gen_statem pid directly."
  @type run :: String.t() | pid()

  @typedoc false
  @type init_arg :: {Item.t(), Project.t(), module(), keyword()}

  @typep data :: %{
           run_id: String.t(),
           item: Item.t(),
           project: Project.t(),
           adapter: module(),
           subscriber: pid() | nil,
           result_store: ResultStore.store(),
           batch_id: String.t(),
           requested_model: String.t() | nil,
           started_at_ms: integer(),
           total_timeout: timeout() | nil,
           idle_timeout: timeout() | nil,
           progress_timeout: timeout() | nil,
           lifetime_timeout: pos_integer(),
           max_hold_timeout: timeout(),
           terminal_linger: non_neg_integer(),
           max_review_iterations: non_neg_integer(),
           review_iterations: non_neg_integer(),
           reviewer: atom() | module() | nil,
           reviewer_adapter: module() | nil,
           reviewer_adapter_opts: keyword(),
           reviewer_stuck_report: String.t() | nil,
           review_green: boolean(),
           implementer_empty_diff?: boolean(),
           hold_requested: false | :graceful | :interrupt,
           hold_reason: :graceful | :interrupt | nil,
           operator_feedback: String.t() | nil,
           in_run_discernment: keyword(),
           checks: [Check.t()] | nil,
           verification_timeout: timeout() | nil,
           base_dir: String.t() | nil,
           base_ref: String.t() | nil,
           adapter_opts: keyword(),
           env: %{optional(String.t()) => String.t() | false},
           land_attempt: pos_integer(),
           worktree: Worktree.t() | nil,
           checkout_snapshot: String.t() | nil,
           pollution_allowlist: [String.t()],
           agent_run: AgentRun.t() | nil,
           agent_outcome: Outcome.t() | nil,
           composed_inputs: [AgentAdapter.composed_input()],
           verdict: Verdict.t() | nil,
           token_usage: TokenUsage.t(),
           first_attempt_failed_check_count: non_neg_integer(),
           agent_diff_size: non_neg_integer() | nil,
           task: Task.t() | nil,
           discernment_task: Task.t() | nil,
           last_discernment_sample_ms: integer() | nil,
           cancel_requested: {Result.reason(), :gen_statem.from() | nil} | nil,
           reason: Result.reason() | nil,
           result: Result.t() | nil,
           transcript: binary(),
           transcript_bytes: non_neg_integer(),
           transcript_seq: non_neg_integer(),
           agent_kind: Parser.agent_kind() | nil,
           transcript_events: [Parser.event()],
           transcript_parser_state: Parser.parser_state() | nil
         }

  @typep event :: :enter | :gen_statem.event_type()
  @typep handler_result ::
           :keep_state_and_data
           | {:keep_state_and_data, [:gen_statem.action()]}
           | {:keep_state, data()}
           | {:keep_state, data(), [:gen_statem.action()]}
           | {:next_state, state(), data()}
           | {:next_state, state(), data(), [:gen_statem.action()]}
           | {:repeat_state, data()}
           | {:stop, term(), data()}

  # ── Public API ────────────────────────────────────────────────────────────

  @doc false
  @spec child_spec(init_arg()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary, type: :worker}
  end

  @doc false
  @spec start_link(init_arg()) :: :gen_statem.start_ret()
  def start_link({%Item{}, %Project{} = _project, adapter, opts} = arg) when is_atom(adapter) and is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    :gen_statem.start_link({:via, Registry, {@registry, run_id}}, __MODULE__, arg, [])
  end

  api(:status, "Return a Harness.Run.Status snapshot of one in-flight or lingering-terminal run.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description:
          "A run handle: run id string (from list_runs/0 or start_run/4) or the gen_statem pid directly. A run that has stopped is unregistered and returns {:error, :not_found}."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Harness.Run.Status{}} carrying state, worktree_path, agent_os_pid, agent_kind, verdict_status, review_iterations, reason. {:error, :not_found} for stopped/unknown runs."
    }
  )

  @spec status(run()) :: {:ok, Status.t()} | {:error, :not_found}
  def status(run) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :status)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(
    :transcript,
    "Return the buffered agent transcript and last seq tag for an in-flight or lingering run.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{buffer: binary, seq: non_neg_integer}} — buffer is bounded at 200 KiB; seq is the monotonic counter for the last chunk (0 when nothing yet). {:error, :not_found} for stopped/unknown runs. Used by the dashboard transcript pane subscribe-then-snapshot pattern."
    }
  )

  @spec transcript(run()) ::
          {:ok, %{buffer: binary(), seq: non_neg_integer()}} | {:error, :not_found}
  def transcript(run) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :transcript)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(
    :transcript_events,
    "Return the parsed transcript event list + last seq tag for an in-flight or lingering run.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{events: [Parser.event()], agent_kind: Parser.agent_kind() | nil, seq: non_neg_integer}} — events are the cumulative bounded list (default cap 500) parsed via Harness.Dashboard.Transcript.Parser; agent_kind is the executing adapter's atom (or nil for unregistered adapters / test doubles); seq mirrors transcript/1's counter. {:error, :not_found} for stopped/unknown runs."
    }
  )

  @spec transcript_events(run()) ::
          {:ok,
           %{
             events: [Parser.event()],
             agent_kind: Parser.agent_kind() | nil,
             seq: non_neg_integer()
           }}
          | {:error, :not_found}
  def transcript_events(run) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :transcript_events)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(:cancel, "Cancel an in-flight Harness.Run: kills the agent and settles the run :failed.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ]
    ],
    returns: %{
      type: :atom,
      description: ":ok — idempotent. Cancelling an already-settled or unknown run is a no-op."
    }
  )

  @spec cancel(run()) :: :ok
  def cancel(run) do
    case resolve(run) do
      {:ok, pid} -> :gen_statem.call(pid, :cancel)
      {:error, :not_found} -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  api(
    :hold,
    "Park a live run in :held for operator-mediated recovery. Graceful hold waits for the current agent attempt to finish; interrupt: true kills the agent immediately.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ],
      interrupt: [
        kind: :value,
        type: :boolean,
        default: false,
        description: "When true, terminate the agent now and park immediately."
      ]
    ],
    returns: %{
      type: :tuple,
      description: ":ok | {:error, :terminal} | {:error, :invalid_state} | {:error, :not_found}"
    }
  )

  @spec hold(run(), boolean()) :: :ok | {:error, :terminal | :invalid_state | :not_found}
  def hold(run, interrupt \\ false) do
    case resolve(run) do
      {:ok, pid} -> :gen_statem.call(pid, {:hold, interrupt})
      {:error, :not_found} -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(
    :steer,
    "Stash operator guidance for the next agent boundary (append-accumulates). Requires session_resume on the adapter.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ],
      text: [kind: :value, type: :string, description: "Operator note for the next resumed attempt."]
    ],
    returns: %{
      type: :tuple,
      description: ":ok | {:error, :resume_unsupported} | {:error, :not_found}"
    }
  )

  @spec steer(run(), String.t()) :: :ok | {:error, :resume_unsupported | :not_found}
  def steer(run, text) when is_binary(text) do
    case resolve(run) do
      {:ok, pid} -> :gen_statem.call(pid, {:steer, text})
      {:error, :not_found} -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(:resume, "Resume a :held run — re-enters :running with a session-resume invocation in the same worktree.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ]
    ],
    returns: %{
      type: :tuple,
      description: ":ok | {:error, :not_held} | {:error, :not_found}"
    }
  )

  @spec resume(run()) :: :ok | {:error, :not_held | :not_found}
  def resume(run) do
    case resolve(run) do
      {:ok, pid} -> :gen_statem.call(pid, :resume)
      {:error, :not_found} -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @spec resolve(run()) :: {:ok, pid()} | {:error, :not_found}
  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve(run_id) when is_binary(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # ── gen_statem setup ──────────────────────────────────────────────────────

  @doc false
  @impl :gen_statem
  @spec callback_mode() :: [:state_functions | :state_enter]
  def callback_mode, do: [:state_functions, :state_enter]

  @doc false
  @impl :gen_statem
  @spec init(init_arg()) :: {:ok, :dispatched, data(), [:gen_statem.action()]}
  def init({item, %Project{} = project, adapter, opts}) do
    run_id = Keyword.fetch!(opts, :run_id)

    # Overlay the operator's persisted landing override onto the project so the
    # landing decision (`maybe_enqueue_landing/2`) and everything downstream act
    # on the *effective* policy, not the static registration-time default. This
    # is the single chokepoint every dispatch path funnels through.
    project = LandingSettings.overlay(project)

    data = %{
      run_id: run_id,
      item: item,
      project: project,
      adapter: adapter,
      subscriber: Keyword.get(opts, :subscriber),
      result_store: Keyword.get(opts, :result_store, ResultStore.configured()),
      batch_id: Keyword.get(opts, :batch_id) || run_id,
      requested_model: Keyword.get(opts, :requested_model) || item.model,
      started_at_ms: System.monotonic_time(:millisecond),
      total_timeout: Keyword.get(opts, :total_timeout),
      idle_timeout: Keyword.get(opts, :idle_timeout),
      progress_timeout: Keyword.get(opts, :progress_timeout),
      lifetime_timeout:
        Keyword.get(opts, :lifetime_timeout) ||
          configured(:lifetime_timeout, @default_lifetime_timeout),
      max_hold_timeout:
        Keyword.get(opts, :max_hold_timeout) ||
          configured(:max_hold_timeout, @default_max_hold_timeout),
      terminal_linger:
        Keyword.get(opts, :terminal_linger) ||
          configured(:terminal_linger, @default_terminal_linger),
      max_review_iterations:
        Keyword.get(opts, :max_review_iterations) ||
          configured(:max_review_iterations, @default_max_review_iterations),
      review_iterations: 0,
      reviewer: Keyword.get(opts, :reviewer, configured(:reviewer, nil)),
      reviewer_adapter: nil,
      reviewer_adapter_opts: Keyword.get(opts, :reviewer_adapter_opts, []),
      reviewer_stuck_report: nil,
      review_green: Keyword.get(opts, :review_green, project.review_green),
      implementer_empty_diff?: false,
      hold_requested: false,
      hold_reason: nil,
      operator_feedback: nil,
      in_run_discernment: in_run_discernment_opts(opts),
      checks: Keyword.get(opts, :checks),
      verification_timeout: Keyword.get(opts, :verification_timeout),
      base_dir: Keyword.get(opts, :base_dir),
      base_ref: Keyword.get(opts, :base_ref),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      env: Keyword.get(opts, :env, %{}),
      land_attempt: Keyword.get(opts, :land_attempt, 1),
      worktree: nil,
      checkout_snapshot: nil,
      pollution_allowlist: resolve_pollution_allowlist(project, opts),
      agent_run: nil,
      agent_outcome: nil,
      composed_inputs: [],
      verdict: nil,
      token_usage: TokenUsage.empty(),
      first_attempt_failed_check_count: 0,
      agent_diff_size: nil,
      task: nil,
      discernment_task: nil,
      last_discernment_sample_ms: nil,
      cancel_requested: nil,
      reason: nil,
      result: nil,
      transcript: <<>>,
      transcript_bytes: 0,
      transcript_seq: 0,
      agent_kind: agent_kind_for(adapter),
      transcript_events: [],
      transcript_parser_state: init_parser_state(adapter)
    }

    {:ok, :dispatched, data, [{{:timeout, :lifetime}, data.lifetime_timeout, :lifetime}]}
  end

  # ── State: dispatched — carve + provision the isolated worktree ───────────

  @doc false
  @spec dispatched(event(), term(), data()) :: handler_result()
  def dispatched(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:dispatched, data))
    task = start_task(fn -> Worktree.create(data.project, worktree_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  def dispatched(:info, {ref, {:ok, %Worktree{} = worktree}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil, worktree: worktree}

    with :ok <- Worktree.activate(worktree),
         :ok <- Isolation.validate(data.adapter) do
      # Warm the worktree (check-stack setup: deps fetch + compile) before the
      # agent spawns, so the agent never burns its idle/progress budget on a
      # silent cold first build. Verification re-runs the same setup later as a
      # fast no-op.
      task = start_task(fn -> Verification.prepare(worktree.path, verification_opts(data)) end)
      {:keep_state, %{data | task: task}}
    else
      {:error, {:worktree_isolation_unsupported, _adapter, _message} = reason} ->
        fail(data, {:agent_spawn_failed, reason})

      {:error, reason} ->
        fail(data, {:worktree_failed, reason})
    end
  end

  # Provisioning finished — the worktree is warm; hand it to the agent.
  def dispatched(:info, {ref, :ok}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {:next_state, :running, %{data | task: nil}}
  end

  # Worktree creation or provisioning failed — both are environment errors.
  def dispatched(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:worktree_failed, reason})
  end

  def dispatched(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:worktree_failed, reason})
  end

  def dispatched(event_type, event_content, data) do
    handle_common(event_type, event_content, :dispatched, data)
  end

  # ── State: running — the agent works in the worktree ──────────────────────

  @doc false
  @spec running(event(), term(), data()) :: handler_result()
  # Entering `running` always means a fresh agent is about to spawn — the first
  # dispatch, or a repair attempt. `agent_run` / `agent_outcome` are reset so a
  # stale handle from a prior attempt never misleads the cancel-defer logic or a
  # `status/1` snapshot.
  def running(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:running, data))
    parent = self()
    invocation = build_invocation(data)
    checkout_snapshot = checkout_snapshot_for_run(data)
    task = start_task(fn -> Driver.run(data.adapter, invocation, driver_opts(data, parent)) end)

    {:keep_state,
     %{
       data
       | task: task,
         checkout_snapshot: checkout_snapshot,
         agent_run: nil,
         agent_outcome: nil
     }}
  end

  def running(:info, {:run_handle, %AgentRun{} = run}, data) do
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
        {:keep_state, data}
    end
  end

  def running(
        :info,
        {ref, {:ok, %{verdict: verdict, outcome: %Outcome{} = outcome}}},
        %{discernment_task: %Task{ref: ref}} = data
      ) do
    Process.demonitor(ref, [:flush])

    handle_in_run_discernment_outcome(%{data | discernment_task: nil}, verdict, outcome)
  end

  def running(:info, {ref, {:error, reason}}, %{discernment_task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    Logger.warning("harness run: in-run discernment grader failed for #{data.run_id}: #{inspect(reason)}")

    feedback = discernment_failure_feedback({:grader_failed, reason})
    notify_in_run_discernment(data, :notify_only, feedback, {:grader_failed, reason})
    {:keep_state, %{data | discernment_task: nil}}
  end

  def running(:info, {:DOWN, ref, :process, _pid, reason}, %{discernment_task: %Task{ref: ref}} = data)
      when reason != :normal do
    Logger.warning("harness run: in-run discernment grader crashed for #{data.run_id}: #{inspect(reason)}")

    feedback = discernment_failure_feedback({:crashed, reason})
    notify_in_run_discernment(data, :notify_only, feedback, {:grader_failed, {:crashed, reason}})
    {:keep_state, %{data | discernment_task: nil}}
  end

  def running(:info, {ref, {:ok, %Outcome{} = outcome}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    cancel_task(data.discernment_task)

    data =
      %{data | task: nil, discernment_task: nil, agent_outcome: outcome}
      |> finalize_transcript()
      |> accumulate_token_usage(outcome)
      |> clear_operator_steer_after_invocation()

    # Precedence: a user cancel is terminal and must win over reflex re-dispatch,
    # so the reflex clause is gated on `nil` cancel. A cancelled run that also
    # tripped a reflex falls through to do_cancel / pollution rather than being
    # re-dispatched. Pollution still beats cancel (unchanged).
    case {data.hold_requested, data.cancel_requested, outcome.kind, checkout_pollution_reason(data)} do
      {hold, nil, _kind, nil} when hold in [:graceful, :interrupt] ->
        do_hold(data, hold)

      {false, nil, {:reflex_halted, reason}, nil} ->
        route_reflex_halt(data, reason)
        fail(data, {:reflex_halted, reason})

      {false, nil, _kind, nil} ->
        {:next_state, :committing, data}

      {_, {reason, from}, _kind, nil} ->
        do_cancel(data, reason, from)

      {_, _, _kind, pollution_reason} when not is_nil(pollution_reason) ->
        fail(data, pollution_reason)
    end
  end

  def running(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    cancel_task(data.discernment_task)
    fail(%{data | task: nil, discernment_task: nil}, {:agent_spawn_failed, reason})
  end

  def running(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    # Mirrors the do_cancel / timeout paths: if the agent polluted the main
    # checkout AND then crashed the driver, surface the pollution (the agent
    # bug) ahead of the driver crash (the downstream effect).
    pollution_reason = checkout_pollution_reason(data)
    cancel_task(data.discernment_task)
    fail(%{data | task: nil, discernment_task: nil}, pollution_reason || {:driver_crashed, reason})
  end

  def running(event_type, event_content, data) do
    handle_common(event_type, event_content, :running, data)
  end

  # ── State: committing — capture the agent's work on the run branch ────────

  @doc false
  @spec committing(event(), term(), data()) :: handler_result()
  def committing(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:committing, data))
    worktree = data.worktree
    message = commit_message(data)
    task = start_task(fn -> commit_worktree(worktree, message) end)
    {:keep_state, %{data | task: task}}
  end

  def committing(:info, {ref, {:ok, :committed, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {:next_state, :verifying, %{data | task: nil, agent_diff_size: diff_size}}
  end

  # An empty diff is never disposed of here — what it *means* (already
  # implemented vs nothing happened) is the reviewer's judgment, not a
  # disposition branch (Task 162). Verification runs either way; the verdict
  # then routes through the reviewer with empty-diff context.
  def committing(:info, {ref, {:ok, :no_changes, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {:next_state, :verifying, %{data | task: nil, agent_diff_size: diff_size, implementer_empty_diff?: true}}
  end

  def committing(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:commit_failed, reason})
  end

  def committing(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:commit_failed, reason})
  end

  def committing(event_type, event_content, data) do
    handle_common(event_type, event_content, :committing, data)
  end

  # ── State: verifying — grade the worktree ─────────────────────────────────

  @doc false
  @spec verifying(event(), term(), data()) :: handler_result()
  def verifying(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:verifying, data))
    worktree = data.worktree
    task = start_task(fn -> Verification.run(worktree.path, verification_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  def verifying(:info, {ref, {:ok, %Verdict{} = verdict}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    data = %{
      data
      | task: nil,
        verdict: verdict,
        first_attempt_failed_check_count: first_attempt_failed_check_count(data, verdict)
    }

    if Verdict.passed?(verdict) do
      route_green_verdict(data)
    else
      route_red_verdict(data)
    end
  end

  def verifying(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:verification_failed, reason})
  end

  def verifying(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:verifier_crashed, reason})
  end

  def verifying(event_type, event_content, data) do
    handle_common(event_type, event_content, :verifying, data)
  end

  # ── State: reviewing — cross-family reviewer fixes red worktree inline ───

  @doc false
  @spec reviewing(event(), term(), data()) :: handler_result()
  def reviewing(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:reviewing, data))
    task = start_task(fn -> run_reviewer(data) end)
    {:keep_state, %{data | task: task, agent_run: nil}}
  end

  def reviewing(
        :info,
        {ref, {:ok, %{outcome: %Outcome{} = outcome, diff_size: diff_size}}},
        %{task: %Task{ref: ref}} = data
      ) do
    Process.demonitor(ref, [:flush])

    data = %{
      data
      | task: nil,
        reviewer_stuck_report: reviewer_report(outcome),
        agent_diff_size: max(data.agent_diff_size || 0, diff_size)
    }

    {:next_state, :verifying, data}
  end

  def reviewing(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    report = "Reviewer failed to run: #{inspect(reason)}"
    {:next_state, :failed, %{data | task: nil, reason: {:review_stuck, report}, reviewer_stuck_report: report}}
  end

  def reviewing(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    report = "Reviewer crashed: #{inspect(reason)}"
    {:next_state, :failed, %{data | task: nil, reason: {:review_stuck, report}, reviewer_stuck_report: report}}
  end

  def reviewing(event_type, event_content, data) do
    handle_common(event_type, event_content, :reviewing, data)
  end

  # ── State: held — operator-parked, worktree retained ─────────────────────

  @doc false
  @spec held(event(), term(), data()) :: handler_result()
  def held(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:held, data))
    {:keep_state, data, hold_enter_actions(data)}
  end

  def held(:state_timeout, :held_expired, data) do
    fail(data, :hold_expired)
  end

  def held(event_type, event_content, data) do
    handle_common(event_type, event_content, :held, data)
  end

  # ── States: done / failed — terminal ──────────────────────────────────────

  @doc false
  @spec done(event(), term(), data()) :: handler_result()
  def done(:enter, _old_state, data) do
    data = settle(data, :done)
    {:keep_state, data, [{:state_timeout, data.terminal_linger, :shutdown}]}
  end

  def done(:state_timeout, :shutdown, data), do: {:stop, :normal, data}

  def done(event_type, event_content, data) do
    handle_common(event_type, event_content, :done, data)
  end

  @doc false
  @spec failed(event(), term(), data()) :: handler_result()
  def failed(:enter, _old_state, data) do
    data = settle(data, :failed)
    {:keep_state, data, [{:state_timeout, data.terminal_linger, :shutdown}]}
  end

  def failed(:state_timeout, :shutdown, data), do: {:stop, :normal, data}

  def failed(event_type, event_content, data) do
    handle_common(event_type, event_content, :failed, data)
  end

  # ── Cross-cutting events ──────────────────────────────────────────────────

  # Events handled the same way in every state: status queries, cancellation,
  # the lifetime timeout, and stale messages from tasks already consumed or
  # killed.
  @spec handle_common(event(), term(), state(), data()) :: handler_result()
  defp handle_common({:call, from}, :status, state, data) do
    {:keep_state_and_data, [{:reply, from, status_snapshot(state, data)}]}
  end

  defp handle_common({:call, from}, :transcript, _state, data) do
    snapshot = %{buffer: data.transcript, seq: data.transcript_seq}
    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  defp handle_common({:call, from}, :transcript_events, _state, data) do
    snapshot = %{
      events: data.transcript_events,
      agent_kind: data.agent_kind,
      seq: data.transcript_seq
    }

    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  # State-agnostic so a chunk that lands during `:committing` / `:verifying` /
  # `:terminal_linger` still appends — the agent's Port can flush after the
  # gen_statem has already transitioned out of `:running`.
  #
  # Two parallel buffers + broadcasts per chunk: the legacy raw iodata path
  # (Transcript.append/broadcast) keeps `?raw=1` on the run-detail URL alive
  # for one release; the parsed-event path (Transcript.append_chunk/4 +
  # broadcast_events/3) feeds the new `<.transcript_view>` renderer. Subscribers
  # pattern-match whichever shape they want.
  defp handle_common(:info, {:transcript_chunk, chunk}, state, data) do
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

    maybe_sample_in_run_discernment(state, data)
  end

  defp handle_common({:call, from}, :cancel, state, _data) when state in [:done, :failed] do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:hold, _interrupt}, :held, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:hold, _interrupt}, state, _data) when state in [:done, :failed] do
    {:keep_state_and_data, [{:reply, from, {:error, :terminal}}]}
  end

  defp handle_common({:call, from}, {:hold, true}, :running, %{agent_run: nil} = data) do
    {:keep_state, %{data | hold_requested: :interrupt}, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:hold, true}, :running, data) do
    do_hold(data, :interrupt, [{:reply, from, :ok}])
  end

  defp handle_common({:call, from}, {:hold, false}, :running, %{hold_requested: hold} = _data)
       when hold in [:graceful, :interrupt] do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:hold, false}, :running, data) do
    {:keep_state, %{data | hold_requested: :graceful}, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:hold, _interrupt}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_state}}]}
  end

  defp handle_common({:call, from}, {:steer, text}, state, data) when state in [:running, :held] do
    if session_resume_supported?(data) do
      {:keep_state, apply_steer(data, text), [{:reply, from, :ok}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :resume_unsupported}}]}
    end
  end

  defp handle_common({:call, from}, :resume, :held, data) do
    do_resume(data, from)
  end

  defp handle_common({:call, from}, :resume, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_held}}]}
  end

  defp handle_common({:call, from}, :cancel, :running, %{agent_run: nil} = data) do
    # The agent has spawned but its handle has not arrived yet — defer the
    # cancel until {:run_handle, _} lands, so the agent can actually be killed.
    {:keep_state, %{data | cancel_requested: {:cancelled, from}}}
  end

  defp handle_common({:call, from}, :cancel, _state, data) do
    do_cancel(data, :cancelled, from)
  end

  defp handle_common({:timeout, :lifetime}, :lifetime, state, _data) when state in [:done, :failed, :held] do
    :keep_state_and_data
  end

  defp handle_common({:timeout, :lifetime}, :lifetime, _state, data) do
    force_settle_lifetime(data)
  end

  # Stale task messages (a result or DOWN from a task already consumed or
  # killed) and any other unrecognised info — ignored.
  defp handle_common(:info, _content, _state, _data), do: :keep_state_and_data

  # Defensive catch-all for any other event type.
  defp handle_common(_type, _content, _state, _data), do: :keep_state_and_data

  # ── Cancellation & settling ───────────────────────────────────────────────

  # Aborts an in-flight run: kills the current step task, SIGKILLs the agent if
  # one is running, and settles `failed`. `from` is the caller awaiting a cancel
  # reply, or `nil` for a timeout-triggered abort.
  @spec do_hold(data(), :graceful | :interrupt, [:gen_statem.action()]) :: handler_result()
  defp do_hold(data, mode, extra_actions \\ []) do
    cancel_task(data.task)
    cancel_task(data.discernment_task)
    terminate_agent(data)

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

  @spec do_resume(data(), :gen_statem.from()) :: handler_result()
  defp do_resume(data, from) do
    data = %{data | hold_reason: nil}

    {:next_state, :running, data,
     [
       {:reply, from, :ok},
       {{:timeout, :lifetime}, data.lifetime_timeout, :lifetime}
     ]}
  end

  @spec hold_enter_actions(data()) :: [:gen_statem.action()]
  defp hold_enter_actions(data) do
    [{{:timeout, :lifetime}, :infinity, :lifetime}] ++ hold_expiry_actions(data)
  end

  @spec hold_expiry_actions(data()) :: [:gen_statem.action()]
  defp hold_expiry_actions(%{max_hold_timeout: :infinity}), do: []

  defp hold_expiry_actions(%{max_hold_timeout: timeout}) when is_integer(timeout) and timeout > 0 do
    [{:state_timeout, timeout, :held_expired}]
  end

  @spec apply_steer(data(), String.t()) :: data()
  defp apply_steer(data, text) do
    feedback =
      case data.operator_feedback do
        nil -> text
        existing -> existing <> "\n\n" <> text
      end

    %{data | operator_feedback: feedback}
  end

  @spec session_resume_supported?(data()) :: boolean()
  defp session_resume_supported?(data) do
    AgentAdapter.supports?(data.adapter, :session_resume)
  end

  @spec clear_operator_steer(data()) :: data()
  defp clear_operator_steer(data) do
    %{data | operator_feedback: nil}
  end

  @spec clear_operator_steer_after_invocation(data()) :: data()
  defp clear_operator_steer_after_invocation(%{operator_feedback: feedback} = data) when is_binary(feedback),
    do: clear_operator_steer(data)

  defp clear_operator_steer_after_invocation(data), do: data

  @spec do_cancel(data(), Result.reason(), :gen_statem.from() | nil) :: handler_result()
  defp do_cancel(data, reason, from) do
    cancel_task(data.task)
    cancel_task(data.discernment_task)
    terminate_agent(data)
    reason = checkout_pollution_reason(data) || reason
    data = %{data | task: nil, discernment_task: nil, agent_run: nil, cancel_requested: nil, reason: reason}
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
  @spec force_settle_lifetime(data()) :: handler_result()
  defp force_settle_lifetime(data) do
    cancel_task(data.task)
    cancel_task(data.discernment_task)
    terminate_agent(data)
    actions = pending_cancel_reply(data)
    reason = checkout_pollution_reason(data) || :timed_out
    data = %{data | task: nil, discernment_task: nil, agent_run: nil, cancel_requested: nil, reason: reason}
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
  @spec fail(data(), Result.reason()) :: handler_result()
  defp fail(data, reason) do
    cancel_task(data.discernment_task)
    terminate_agent(data)

    {:next_state, :failed, %{data | discernment_task: nil, agent_run: nil, cancel_requested: nil, reason: reason},
     pending_cancel_reply(data)}
  end

  @spec pending_cancel_reply(data()) :: [:gen_statem.action()]
  defp pending_cancel_reply(%{cancel_requested: {_reason, from}}) when is_tuple(from) do
    [{:reply, from, :ok}]
  end

  defp pending_cancel_reply(_data), do: []

  @spec cancel_task(Task.t() | nil) :: :ok
  defp cancel_task(nil), do: :ok

  defp cancel_task(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  @spec terminate_agent(data()) :: :ok
  defp terminate_agent(%{agent_run: nil}), do: :ok

  defp terminate_agent(%{agent_run: %AgentRun{} = run, adapter: adapter}) do
    adapter.terminate(run)
    :ok
  end

  @spec route_reflex_halt(data(), term()) :: :ok
  defp route_reflex_halt(data, reason) do
    case Resilience.route({:reflex_halt, reason}, resilience_args(data)) do
      :ok ->
        :ok

      {:cancel, {:blocked, blocked_reason}} ->
        Logger.warning("harness run: reflex halt blocked task #{data.item.id}: #{blocked_reason}")

      {:error, route_reason} ->
        Logger.warning("harness run: reflex halt route failed for task #{data.item.id}: #{inspect(route_reason)}")
    end

    :ok
  end

  @spec resilience_args(data()) :: map()
  defp resilience_args(data) do
    %{
      "project_name" => data.project.name,
      "run_id" => data.run_id,
      "task_id" => to_string(data.item.id),
      "agent" => to_string(data.item.agent),
      "branch" => "harness/" <> data.run_id,
      "land_attempt" => data.land_attempt
    }
  end

  # Builds and persists the final result, tears the worktree down, then delivers
  # it to the subscriber. Teardown errors are logged and swallowed so the result
  # is still delivered, but subscribers do not race test/driver fixture cleanup.
  @spec settle(data(), Result.state()) :: data()
  defp settle(data, terminal_state) do
    result = build_result(data, terminal_state)
    data = %{data | result: result}
    persist_run_record(data, result)
    finish_worktree(data.worktree, terminal_state)
    notify_subscriber(data.subscriber, data.run_id, result)
    RunFeed.broadcast_settled(status_snapshot(terminal_state, data))
    maybe_enqueue_landing(data, terminal_state)
    data
  end

  # Autonomous merge-train trigger: a run that settles green under a project that
  # opts into landing (`landing_policy: :auto` + a non-empty `target_branch`)
  # enqueues exactly one landing job onto the project's serialized `landing_<name>`
  # queue. Every other terminal state — red verdict, failure, `:manual` project,
  # or a project with no `target_branch` — enqueues nothing.
  @spec maybe_enqueue_landing(data(), Result.state()) :: :ok
  defp maybe_enqueue_landing(
         %{reason: :passed, project: %Project{landing_policy: :auto, target_branch: tb} = project} = data,
         :done
       )
       when is_binary(tb) and tb != "" do
    %{
      "project_name" => project.name,
      "run_id" => data.run_id,
      "task_id" => to_string(data.item.id),
      "agent" => to_string(data.item.agent),
      "branch" => "harness/" <> data.run_id,
      "land_attempt" => data.land_attempt
    }
    |> LanderWorker.new(queue: HarnessOban.landing_queue_name(project))
    |> HarnessOban.insert()
    |> log_landing_enqueue(data.run_id)
  end

  defp maybe_enqueue_landing(_data, _terminal_state), do: :ok

  @spec log_landing_enqueue({:ok, Job.t()} | {:error, term()}, String.t()) :: :ok
  defp log_landing_enqueue({:ok, _job}, run_id) do
    Logger.info("harness run: enqueued autonomous landing for run #{run_id}")
    :ok
  end

  defp log_landing_enqueue({:error, reason}, run_id) do
    Logger.warning("harness run: failed to enqueue landing for run #{run_id}: #{inspect(reason)}")
    :ok
  end

  @spec build_result(data(), Result.state()) :: Result.t()
  defp build_result(data, terminal_state) do
    %Result{
      run_id: data.run_id,
      task_id: data.item.id,
      state: terminal_state,
      reason: data.reason,
      agent_outcome: data.agent_outcome,
      verdict: data.verdict,
      worktree_path: data.worktree && data.worktree.path,
      reviewer_adapter: data.reviewer_adapter,
      review_iterations: data.review_iterations,
      reviewer_stuck_report: data.reviewer_stuck_report,
      first_attempt_failed_check_count: data.first_attempt_failed_check_count,
      agent_diff_size: data.agent_diff_size,
      token_usage: data.token_usage,
      composed_inputs: data.composed_inputs
    }
  end

  # Parses the just-settled attempt's transcript for token usage and sums it into
  # the run's running total, so a multi-attempt repair loop's burn is attributable.
  # `agent_kind: nil` (test doubles, unregistered adapters) parses to an empty
  # usage, so the total stays an empty usage — never a crash.
  #
  # Grok is the exception: its stdout omits usage entirely, so the figure is
  # recovered from grok's on-disk session log (`GrokSession`). That log records a
  # *cumulative* total across `--continue` repair attempts, so the recovered
  # value REPLACES the running total rather than summing per attempt; only when
  # recovery yields nothing do we fall back to the (empty) stdout parse.
  @spec accumulate_token_usage(data(), Outcome.t()) :: data()
  defp accumulate_token_usage(%{agent_kind: :grok} = data, %Outcome{output: output}) do
    case GrokSession.usage(output) do
      %TokenUsage{} = recovered when recovered.total != nil -> %{data | token_usage: recovered}
      _ -> %{data | token_usage: TokenUsage.add(data.token_usage, TokenUsage.parse(:grok, output))}
    end
  end

  defp accumulate_token_usage(data, %Outcome{output: output}) do
    attempt = TokenUsage.parse(data.agent_kind, output)
    %{data | token_usage: TokenUsage.add(data.token_usage, attempt)}
  end

  @spec persist_run_record(data(), Result.t()) :: :ok
  defp persist_run_record(data, %Result{} = result) do
    result
    |> LogRecord.from_result(
      batch_id: data.batch_id,
      agent: data.item.agent,
      requested_model: data.requested_model,
      adapter: data.adapter,
      project_name: data.project.name,
      duration_ms: run_duration_ms(data),
      domains: data.item.domains
    )
    |> ResultStore.record_run(data.result_store)
    |> log_store_error(result.run_id)
  end

  @spec log_store_error(:ok | {:error, term()}, String.t()) :: :ok
  defp log_store_error(:ok, _run_id), do: :ok

  defp log_store_error({:error, reason}, run_id) do
    Logger.warning("harness run: failed to persist run record #{run_id}: #{inspect(reason)}")
    :ok
  end

  @spec run_duration_ms(data()) :: non_neg_integer()
  defp run_duration_ms(data) do
    max(0, System.monotonic_time(:millisecond) - data.started_at_ms)
  end

  @spec notify_subscriber(pid() | nil, String.t(), Result.t()) :: :ok
  defp notify_subscriber(nil, _run_id, _result), do: :ok

  defp notify_subscriber(subscriber, run_id, result) do
    send(subscriber, {:harness_run, run_id, result})
    :ok
  end

  @spec finish_worktree(Worktree.t() | nil, Result.state()) :: :ok
  defp finish_worktree(nil, _terminal_state), do: :ok

  defp finish_worktree(%Worktree{} = worktree, terminal_state) do
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

  @spec status_snapshot(state(), data()) :: Status.t()
  defp status_snapshot(state, data) do
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
      worktree_path: data.worktree && data.worktree.path,
      agent_os_pid: data.agent_run && data.agent_run.os_pid,
      agent_kind: data.agent_outcome && data.agent_outcome.kind,
      verdict_status: data.verdict && data.verdict.status,
      review_iterations: data.review_iterations,
      reason: data.reason,
      held?: state == :held,
      hold_reason: if(state == :held, do: data.hold_reason)
    }
  end

  @spec start_task((-> term())) :: Task.t()
  defp start_task(fun) do
    Task.Supervisor.async_nolink(@task_supervisor, fun)
  end

  # The first dispatch runs the task prompt fresh; an operator-steered resume
  # re-enters the agent's session with the steer prompt. There is no repair
  # loop — a red verdict is the cross-family reviewer's to fix, never a
  # procedural re-dispatch (docs/reviewer-pair-architecture.md).
  @spec build_invocation(data()) :: Invocation.t()
  defp build_invocation(%{operator_feedback: feedback} = data) when is_binary(feedback) do
    invocation(data, operator_steer_prompt(data), :resume)
  end

  defp build_invocation(data) do
    invocation(data, data.item.prompt, nil)
  end

  @spec invocation(data(), String.t(), :resume | nil) :: Invocation.t()
  defp invocation(data, prompt, session) do
    %Invocation{
      prompt: prompt,
      cwd: data.worktree.path,
      task_id: data.item.id,
      session: session,
      permission_mode: :autonomous,
      language: project_language(data.project),
      adapter_opts: data.adapter_opts,
      env: data.env
    }
  end

  @spec tag_composed_input(AgentRun.t(), data()) :: AgentAdapter.composed_input()
  defp tag_composed_input(%AgentRun{composed_input: input}, data) when is_map(input) do
    input
    |> Map.put(:attempt, length(data.composed_inputs))
    |> Map.put(:phase, composed_input_phase(input, data))
  end

  defp tag_composed_input(%AgentRun{}, data) do
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

  @spec composed_input_phase(AgentAdapter.composed_input(), data()) :: :initial | :steer
  defp composed_input_phase(%{session: :resume}, _data), do: :steer

  defp composed_input_phase(_input, data), do: composed_input_phase_for_data(data)

  @spec composed_input_phase_for_data(data()) :: :initial | :steer
  defp composed_input_phase_for_data(%{operator_feedback: feedback}) when is_binary(feedback), do: :steer
  defp composed_input_phase_for_data(_data), do: :initial

  @spec operator_steer_prompt(data()) :: String.t()
  defp operator_steer_prompt(%{operator_feedback: feedback} = data) when is_binary(feedback) do
    header = """
    An operator has reviewed your progress and sent this guidance:

    #{feedback}
    """

    case data.verdict do
      %Verdict{status: :fail} = verdict ->
        evidence = failing_check_evidence(verdict)

        if evidence == "" do
          header
        else
          header <> "\n\nLast verification failing checks:\n\n" <> evidence
        end

      _ ->
        header
    end
  end

  @spec project_language(Project.t()) :: atom() | nil
  defp project_language(%Project{check_stacks: [%{name: language}]}) when is_atom(language), do: language
  defp project_language(%Project{}), do: nil

  @spec route_red_verdict(data()) :: handler_result()
  defp route_red_verdict(data) do
    cond do
      data.max_review_iterations == 0 ->
        {:next_state, :failed, %{data | reason: :verification_red}}

      data.review_iterations >= data.max_review_iterations ->
        report = data.reviewer_stuck_report || "Reviewer iterations exhausted while verification remained red."
        {:next_state, :failed, %{data | reason: {:review_stuck, report}, reviewer_stuck_report: report}}

      true ->
        case select_reviewer(data) do
          {:ok, reviewer} ->
            {:next_state, :reviewing,
             %{
               data
               | reviewer_adapter: reviewer,
                 review_iterations: data.review_iterations + 1,
                 reviewer_stuck_report: nil
             }}

          {:error, reason} ->
            report = "No cross-family reviewer adapter available: #{inspect(reason)}"
            {:next_state, :failed, %{data | reason: {:review_stuck, report}, reviewer_stuck_report: report}}
        end
    end
  end

  # A green verdict settles :done unless it still owes a reviewer pass: an
  # empty implementer diff always owes one ("what does an empty diff mean?" is
  # the reviewer's judgment), and a project with `review_green: true` owes one
  # conformance pass. Exactly one — the `review_iterations == 0` guard makes
  # the post-review green verdict settle. A wanted-but-unavailable reviewer
  # fails OPEN to :done (Task 158's lesson): the check stack is the ground
  # truth, and green work must never fail on missing review infrastructure.
  @spec route_green_verdict(data()) :: handler_result()
  defp route_green_verdict(data) do
    if green_review_wanted?(data) do
      case select_reviewer(data) do
        {:ok, reviewer} ->
          {:next_state, :reviewing,
           %{
             data
             | reviewer_adapter: reviewer,
               review_iterations: data.review_iterations + 1,
               reviewer_stuck_report: nil
           }}

        {:error, _reason} ->
          settle_done(data)
      end
    else
      settle_done(data)
    end
  end

  @spec green_review_wanted?(data()) :: boolean()
  defp green_review_wanted?(data) do
    data.max_review_iterations > 0 and
      data.review_iterations == 0 and
      (data.review_green or data.implementer_empty_diff?)
  end

  @spec settle_done(data()) :: handler_result()
  defp settle_done(data) do
    {:next_state, :done, clear_operator_steer(%{data | reason: :passed})}
  end

  @spec select_reviewer(data()) :: {:ok, module()} | {:error, term()}
  defp select_reviewer(%{reviewer: nil} = data) do
    implementer = data.item.agent

    AgentRegistry.agents()
    |> Enum.reject(fn {agent, _module} -> agent == implementer end)
    |> Enum.find_value(fn {_agent, module} ->
      if reviewer_dispatchable?(module), do: {:ok, module}
    end)
    |> case do
      {:ok, module} -> {:ok, module}
      nil -> {:error, {:no_cross_family_reviewer, implementer}}
    end
  end

  defp select_reviewer(%{reviewer: reviewer} = data) do
    with {:ok, module} <- resolve_reviewer(reviewer),
         :ok <- ensure_cross_family_reviewer(data.item.agent, module),
         true <- explicit_reviewer_dispatchable?(module) || {:error, {:reviewer_unavailable, module}} do
      {:ok, module}
    end
  end

  @spec resolve_reviewer(atom() | module()) :: {:ok, module()} | {:error, term()}
  defp resolve_reviewer(reviewer) when is_atom(reviewer) do
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

  @spec ensure_cross_family_reviewer(atom(), module()) :: :ok | {:error, term()}
  defp ensure_cross_family_reviewer(implementer, reviewer_module) do
    case AgentRegistry.agent_for_module(reviewer_module) do
      {:ok, ^implementer} -> {:error, {:same_family_reviewer, implementer, reviewer_module}}
      _other -> :ok
    end
  end

  @spec reviewer_dispatchable?(module()) :: boolean()
  defp reviewer_dispatchable?(module) do
    AgentRegistry.available?(module) and
      AgentRegistry.installed?(module) and
      reviewer_enabled?(module)
  end

  @spec explicit_reviewer_dispatchable?(module()) :: boolean()
  defp explicit_reviewer_dispatchable?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, _agent} -> reviewer_dispatchable?(module)
      {:error, _reason} -> AgentRegistry.available?(module)
    end
  end

  @spec reviewer_enabled?(module()) :: boolean()
  defp reviewer_enabled?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> AgentSettings.enabled?(agent)
      {:error, _reason} -> true
    end
  end

  @spec run_reviewer(data()) ::
          {:ok, %{outcome: Outcome.t(), diff_size: non_neg_integer()}} | {:error, term()}
  defp run_reviewer(data) do
    with {:ok, %Outcome{} = outcome} <-
           Driver.run(data.reviewer_adapter, reviewer_invocation(data), reviewer_driver_opts(data)),
         {:ok, _status, diff_size} <- commit_worktree(data.worktree, reviewer_commit_message(data)) do
      {:ok, %{outcome: outcome, diff_size: diff_size}}
    end
  end

  @spec reviewer_invocation(data()) :: Invocation.t()
  defp reviewer_invocation(data) do
    %Invocation{
      prompt: reviewer_prompt(data),
      cwd: data.worktree.path,
      task_id: "#{data.item.id}-review-#{data.review_iterations}",
      permission_mode: :autonomous,
      language: project_language(data.project),
      adapter_opts: data.reviewer_adapter_opts,
      env: data.env
    }
  end

  @spec reviewer_driver_opts(data()) :: keyword()
  defp reviewer_driver_opts(data) do
    []
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, data.idle_timeout)
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  @spec reviewer_prompt(data()) :: String.t()
  defp reviewer_prompt(data) do
    """
    You are the cross-family reviewer for a harness run.

    #{review_scope_instructions(data)}
    Harness will mechanically re-run the same check stack after you exit. Your words cannot make this run done.

    Implementer: #{data.item.agent}
    Reviewer iteration: #{data.review_iterations} of #{data.max_review_iterations}
    Current commit: #{current_sha(data)}

    Task spec:
    #{empty_placeholder(task_text(data))}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}

    Implementer transcript tail:
    #{empty_placeholder(transcript_tail(data.transcript))}

    Diff stat:
    #{empty_placeholder(diff_stat(data))}

    Full failing-check output:
    #{empty_placeholder(failing_check_evidence(data.verdict))}
    """
  end

  # Which judgment this reviewer pass is being asked to make. Derived, never
  # stored: a green verdict means conformance review, red + an empty implementer
  # diff means "decide what the empty diff means", red otherwise means "fix the
  # worktree". The judgment itself happens in the reviewer agent — these are
  # only the instructions framing it.
  @spec review_scope(data()) :: :fix_red | :empty_diff | :green_conformance
  defp review_scope(data) do
    cond do
      match?(%Verdict{}, data.verdict) and Verdict.passed?(data.verdict) -> :green_conformance
      data.implementer_empty_diff? -> :empty_diff
      true -> :fix_red
    end
  end

  @spec review_scope_instructions(data()) :: String.t()
  defp review_scope_instructions(data) do
    case_result =
      case review_scope(data) do
        :fix_red ->
          """
          The implementer has committed work in this SAME worktree, and the check stack is red.
          Your job: fix inline, commit, re-run checks; end green or write a stuck-report.
          """

        :empty_diff ->
          """
          The implementer produced NO diff in this worktree, and the check stack is red.
          The transcript tail below shows what the implementer did — it may have hit a usage limit,
          crashed, or believed the work was already done. Your job is to decide what the empty diff means:
          - Already implemented: make the checks pass (fix inline, commit) so the run can settle done.
          - Nothing happened: write a stuck-report explaining why (e.g. the implementer hit a usage limit).
          """

        :green_conformance ->
          """
          The check stack in this worktree is GREEN. Your job is NOT to fix red checks.
          Review the implementer's committed work strictly against the task's acceptance criteria below.
          If it conforms, make no changes and exit. If it does not conform, fix inline and commit.
          """
      end

    String.trim_trailing(case_result)
  end

  @spec transcript_tail(String.t()) :: String.t()
  defp transcript_tail(transcript) when byte_size(transcript) <= @reviewer_transcript_tail_bytes, do: transcript

  defp transcript_tail(transcript) do
    tail =
      binary_part(
        transcript,
        byte_size(transcript) - @reviewer_transcript_tail_bytes,
        @reviewer_transcript_tail_bytes
      )

    valid_utf8_tail(tail)
  end

  # binary_part/3 can slice mid-codepoint; drop leading bytes until the tail is
  # valid UTF-8 again (at most 3 iterations for UTF-8 input).
  @spec valid_utf8_tail(binary()) :: binary()
  defp valid_utf8_tail(<<>>), do: <<>>

  defp valid_utf8_tail(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_tail(binary_part(bin, 1, byte_size(bin) - 1))
  end

  @spec diff_stat(data()) :: String.t()
  defp diff_stat(data) do
    case Git.run(["diff", "--stat", "#{data.worktree.base_sha}..HEAD"], data.worktree.path) do
      {:ok, stat} -> String.trim(stat)
      {:error, reason} -> "diff stat unavailable: #{inspect(reason)}"
    end
  end

  @spec reviewer_report(Outcome.t()) :: String.t()
  defp reviewer_report(%Outcome{output: output}) when is_binary(output) do
    output
    |> String.trim()
    |> case do
      "" -> "Reviewer exited without a stuck-report."
      text -> text
    end
  end

  @spec reviewer_commit_message(data()) :: String.t()
  defp reviewer_commit_message(data) do
    "harness: reviewer iteration #{data.review_iterations} — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  # ── In-run discernment (sampled live-transcript review) ──────────────────
  #
  # A cross-family grader samples the implementer's partial transcript while it
  # works and can halt a high-confidence rogue/destructive/spinning attempt.
  # The halted attempt routes through the normal pipeline (commit → verify →
  # reviewer); there is no procedural re-dispatch loop.

  @spec grade_discernment(data()) :: {:ok, AuditReview.result()} | {:error, term()}
  defp grade_discernment(data) do
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

  @spec discernment_evidence(data()) :: {:ok, String.t()} | {:error, term()}
  defp discernment_evidence(data) do
    case Git.run(["diff", "--stat", "--patch", "--find-renames", "--no-ext-diff"], data.worktree.path) do
      {:ok, diff} -> {:ok, truncate_semantic_diff(diff)}
      {:error, reason} -> {:error, {:diff_unavailable, reason}}
    end
  end

  @spec discernment_grader(data()) :: {:ok, atom()} | {:error, term()}
  defp discernment_grader(data) do
    discernment_grader(data.item.agent, Keyword.get(data.in_run_discernment, :grader))
  end

  @spec discernment_grader(atom(), term()) :: {:ok, atom()} | {:error, term()}
  defp discernment_grader(implementer, nil), do: AuditReview.default_grader(implementer)

  defp discernment_grader(implementer, grader) when is_atom(grader) do
    case known_grader_agent(grader) do
      {:ok, ^implementer} -> AuditReview.default_grader(implementer)
      _other -> {:ok, grader}
    end
  end

  defp discernment_grader(_implementer, grader), do: {:error, {:invalid_option, :grader, grader}}

  @spec discernment_grader_dispatchable?(atom()) :: boolean()
  defp discernment_grader_dispatchable?(grader) when is_atom(grader) do
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

  @spec known_grader_agent(atom()) :: {:ok, atom()} | :unknown
  defp known_grader_agent(grader) do
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

  @spec handle_in_run_discernment_outcome(data(), AuditReview.verdict(), Outcome.t()) :: handler_result()
  defp handle_in_run_discernment_outcome(data, :unclear, %Outcome{kind: kind})
       when kind in [{:timed_out, :idle}, {:timed_out, :total}] do
    reason = {:grader_failed, kind}
    feedback = discernment_failure_feedback(reason)
    notify_in_run_discernment(data, :notify_only, feedback, reason)
    {:keep_state, data}
  end

  defp handle_in_run_discernment_outcome(data, verdict, %Outcome{} = outcome) do
    feedback = %{
      verdict: verdict,
      rationale: discernment_rationale(outcome.output)
    }

    handle_in_run_discernment_verdict(data, verdict, feedback)
  end

  @spec handle_in_run_discernment_verdict(
          data(),
          AuditReview.verdict(),
          %{verdict: AuditReview.verdict(), rationale: String.t()}
        ) :: handler_result()
  defp handle_in_run_discernment_verdict(data, :reject, feedback) do
    # High-confidence rogue/destructive/spinning behavior: halt the implementer
    # and route whatever it left through the normal pipeline — commit, verify,
    # and let the cross-family reviewer judge the worktree. Never a procedural
    # re-dispatch (docs/reviewer-pair-architecture.md).
    feedback = Map.put(feedback, :trigger, :in_run)
    notify_in_run_discernment(data, :halt, feedback)
    terminate_agent(data)
    cancel_task(data.task)

    {:next_state, :committing, %{data | task: nil, agent_run: nil, cancel_requested: nil}}
  end

  defp handle_in_run_discernment_verdict(data, verdict, feedback) do
    notify_in_run_discernment(data, :notify_only, %{feedback | verdict: verdict})
    {:keep_state, data}
  end

  # The grader could not run (spawn failure, crash, timeout). In-run discernment
  # is advisory: an infrastructure failure is reported, never acted on.
  @spec discernment_failure_feedback(term()) :: %{verdict: AuditReview.verdict(), rationale: String.t()}
  defp discernment_failure_feedback(reason) do
    %{verdict: :unclear, rationale: "In-run discernment grader did not run: #{inspect(reason)}"}
  end

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
  defp notify_in_run_discernment(data, action, feedback, reason \\ nil) do
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

  @spec maybe_put_reason(map(), term() | nil) :: map()
  defp maybe_put_reason(outcome, nil), do: outcome
  defp maybe_put_reason(outcome, reason), do: Map.put(outcome, :reason, reason)

  @spec discernment_prompt(data(), String.t()) :: String.t()
  defp discernment_prompt(data, diff) do
    """
    You are the sampled cross-family semantic discernment reviewer for an in-flight harness run.

    You are reading a PARTIAL live transcript. Agents often read and explore
    before editing, so do not punish uncertainty, quiet exploration, or an
    incomplete solution. Ambiguous or low-confidence concerns must be REPORTED
    in your rationale without a reject sentinel. Emit REJECT only for
    high-confidence rogue/destructive/out-of-scope behavior or productive spin
    that should halt this attempt and re-dispatch with correction.

    Your verdict is demote-only. APPROVE does not bless the run or turn red
    green; it only means "no intervention from this sample."

    Implementer: #{data.item.agent}
    Current commit: #{current_sha(data)}

    Task body:
    #{empty_placeholder(data.item.body)}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}

    Partial live transcript:
    #{empty_placeholder(truncate_semantic_diff(data.transcript))}

    Current uncommitted diff, if any:
    #{empty_placeholder(diff)}

    Return one concise rationale line, then a final sentinel on its own line
    only when confident:
    <<<VERDICT:APPROVE>>>
    or
    <<<VERDICT:REJECT>>>
    """
  end

  @spec truncate_semantic_diff(String.t()) :: String.t()
  defp truncate_semantic_diff(diff) when byte_size(diff) <= @semantic_diff_max_bytes, do: diff

  defp truncate_semantic_diff(diff) do
    head = binary_part(diff, 0, @semantic_diff_max_bytes)

    "[harness: showing the first #{@semantic_diff_max_bytes} of #{byte_size(diff)} bytes]\n" <>
      valid_utf8_head(head)
  end

  @spec valid_utf8_head(binary()) :: binary()
  defp valid_utf8_head(<<>>), do: <<>>

  defp valid_utf8_head(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_head(binary_part(bin, 0, byte_size(bin) - 1))
  end

  @spec empty_placeholder(String.t() | nil) :: String.t()
  defp empty_placeholder(nil), do: "(none)"
  defp empty_placeholder(""), do: "(none)"
  defp empty_placeholder(text), do: text

  @spec format_acceptance_criteria([String.t()]) :: String.t()
  defp format_acceptance_criteria([]), do: "(none)"

  defp format_acceptance_criteria(criteria), do: Enum.map_join(criteria, "\n", fn criterion -> "- #{criterion}" end)

  @spec discernment_rationale(String.t()) :: String.t()
  defp discernment_rationale(output) when is_binary(output) do
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

  @spec failing_check_evidence(Verdict.t()) :: String.t()
  defp failing_check_evidence(%Verdict{results: results}) do
    results
    |> Enum.filter(&(&1.status == :fail))
    |> Enum.map_join("\n\n", &format_check_evidence/1)
  end

  @spec format_check_evidence(CheckResult.t()) :: String.t()
  defp format_check_evidence(%CheckResult{} = result) do
    """
    check: #{result.name}
    status: #{check_status_line(result)}
    command: #{result.command}
    output:
    #{String.trim(result.output)}
    """
  end

  @spec check_status_line(CheckResult.t()) :: String.t()
  defp check_status_line(%CheckResult{kind: :exited, exit_status: status}), do: "exited #{status}"
  defp check_status_line(%CheckResult{kind: :timed_out}), do: "timed out"
  defp check_status_line(%CheckResult{kind: :not_launched}), do: "could not launch"

  @spec maybe_sample_in_run_discernment(state(), data()) :: handler_result()
  defp maybe_sample_in_run_discernment(:running, data) do
    opts = data.in_run_discernment
    now = System.monotonic_time(:millisecond)

    if in_run_discernment_due?(data, opts, now) do
      task = start_task(fn -> grade_discernment(data) end)
      {:keep_state, %{data | discernment_task: task, last_discernment_sample_ms: now}}
    else
      {:keep_state, data}
    end
  end

  defp maybe_sample_in_run_discernment(_state, data), do: {:keep_state, data}

  @spec in_run_discernment_due?(data(), keyword(), integer()) :: boolean()
  defp in_run_discernment_due?(data, opts, now) do
    in_run_discernment_enabled?(opts) and
      is_nil(data.discernment_task) and
      data.transcript_bytes >= Keyword.get(opts, :min_transcript_bytes, @default_discernment_min_transcript_bytes) and
      sample_interval_due?(data.last_discernment_sample_ms, Keyword.get(opts, :sample_interval_ms), now) and
      discernment_weight_passes?(data, opts, now)
  end

  @spec in_run_discernment_enabled?(keyword()) :: boolean()
  defp in_run_discernment_enabled?(opts), do: Keyword.get(opts, :enabled, false) == true

  @spec sample_interval_due?(integer() | nil, non_neg_integer() | nil, integer()) :: boolean()
  defp sample_interval_due?(nil, _interval, _now), do: true

  defp sample_interval_due?(last, nil, now), do: now - last >= @default_discernment_sample_interval_ms

  defp sample_interval_due?(last, interval, now), do: now - last >= interval

  @spec discernment_weight_passes?(data(), keyword(), integer()) :: boolean()
  defp discernment_weight_passes?(data, opts, now) do
    min_weight = Keyword.get(opts, :min_weight, @default_discernment_min_weight)

    explicit_weight = Keyword.get(opts, :weight)

    cond do
      is_integer(explicit_weight) ->
        explicit_weight >= min_weight

      task_difficulty(data) >= min_weight ->
        true

      security_or_bug_marker?(task_text(data)) ->
        true

      long_running?(data, opts, now) ->
        true

      true ->
        false
    end
  end

  @spec task_difficulty(data()) :: non_neg_integer()
  defp task_difficulty(data) do
    case Regex.run(~r/\bD\s*:\s*(\d+)/, task_text(data)) do
      [_, digits] -> String.to_integer(digits)
      _other -> 0
    end
  end

  @spec security_or_bug_marker?(String.t()) :: boolean()
  defp security_or_bug_marker?(text) do
    Regex.match?(~r/\b(security|bug|vulnerability|vulnerable|destructive|rogue)\b/i, text)
  end

  @spec long_running?(data(), keyword(), integer()) :: boolean()
  defp long_running?(data, opts, now) do
    long_running_ms = Keyword.get(opts, :long_running_ms, @default_discernment_long_running_ms)
    now - data.started_at_ms >= long_running_ms
  end

  @spec task_text(data()) :: String.t()
  defp task_text(data) do
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
  @spec in_run_discernment_opts(keyword()) :: keyword()
  defp in_run_discernment_opts(opts) do
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

  @spec current_sha(data()) :: String.t()
  defp current_sha(%{worktree: %Worktree{path: path, base_sha: fallback}}) do
    case Git.run(["rev-parse", "HEAD"], path) do
      {:ok, sha} -> non_empty_sha(String.trim(sha), fallback)
      {:error, _reason} -> fallback
    end
  end

  @spec non_empty_sha(String.t(), String.t()) :: String.t()
  defp non_empty_sha("", fallback), do: fallback
  defp non_empty_sha(sha, _fallback), do: sha

  # The message stamped on the agent's delivery commit — identifies the run and
  # the rmap task it served, so the commit is legible in `git log` after the
  # worktree it came from is gone.
  @spec commit_message(data()) :: String.t()
  defp commit_message(data) do
    "harness: agent delivery — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  @spec worktree_opts(data()) :: keyword()
  defp worktree_opts(data) do
    [id: data.run_id]
    |> put_opt(:base_dir, data.base_dir)
    |> put_opt(:base_ref, data.base_ref)
  end

  @spec driver_opts(data(), pid()) :: keyword()
  defp driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:run_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, data.idle_timeout)
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  @spec verification_opts(data()) :: keyword()
  defp verification_opts(data) do
    opts =
      if data.checks do
        [checks: data.checks]
      else
        [check_stacks: data.project.check_stacks]
      end

    put_opt(opts, :timeout, data.verification_timeout)
  end

  @spec commit_worktree(Worktree.t(), String.t()) ::
          {:ok, :committed | :no_changes, non_neg_integer()} | {:error, Worktree.error()}
  defp commit_worktree(%Worktree{} = worktree, message) do
    with {:ok, diff_size} <- Worktree.diff_size(worktree),
         {:ok, status} <- Worktree.commit(worktree, message) do
      {:ok, status, diff_size}
    end
  end

  # The failed-check count from the FIRST verification pass — the implementer's
  # delivery quality before any reviewer iteration touched the worktree.
  @spec first_attempt_failed_check_count(data(), Verdict.t()) :: non_neg_integer()
  defp first_attempt_failed_check_count(%{verdict: nil}, %Verdict{results: results}) do
    Enum.count(results, &(&1.status == :fail))
  end

  defp first_attempt_failed_check_count(data, _verdict), do: data.first_attempt_failed_check_count

  @spec put_opt(keyword(), atom(), term()) :: keyword()
  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec normalize_opts(nil | keyword() | map()) :: keyword()
  defp normalize_opts(nil), do: []
  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)

  @spec checkout_snapshot_for_run(data()) :: String.t() | nil
  defp checkout_snapshot_for_run(data) do
    if AgentAdapter.supports?(data.adapter, :worktree_isolation) do
      nil
    else
      checkout_snapshot(Project.repo_path(data.project))
    end
  end

  @spec checkout_snapshot(String.t()) :: String.t() | nil
  defp checkout_snapshot(repo) when is_binary(repo) do
    case Reflex.checkout_snapshot(repo) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        Logger.warning("harness run: checkout snapshot failed for #{repo}: #{inspect(reason)}")
        nil
    end
  end

  @spec checkout_pollution_reason(data()) :: Result.reason() | nil
  defp checkout_pollution_reason(data) do
    opts = [pollution_allowlist: data.pollution_allowlist]

    Reflex.checkout_pollution_reason(Project.repo_path(data.project), data.checkout_snapshot, opts)
  end

  @spec resolve_pollution_allowlist(Project.t(), keyword()) :: [String.t()]
  defp resolve_pollution_allowlist(project, opts) do
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

  @spec configured(atom(), term()) :: term()
  defp configured(key, default) do
    :harness |> Application.get_env(:run, []) |> Keyword.get(key, default)
  end

  # Resolves the adapter module back to its `Parser.agent_kind` atom for the
  # transcript parser. Returns `nil` for unregistered adapters (test doubles,
  # ad-hoc invocations) so the run still functions — the parsed-event surface
  # stays empty in that case and only `?raw=1` shows anything in the dashboard.
  @spec agent_kind_for(module()) :: Parser.agent_kind() | nil
  defp agent_kind_for(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, kind} -> kind
      {:error, _} -> nil
    end
  end

  @spec init_parser_state(module()) :: Parser.parser_state() | nil
  defp init_parser_state(adapter) do
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
  @spec parse_chunk(data(), iodata()) ::
          {[Parser.event()], [Parser.event()], Parser.parser_state() | nil}
  defp parse_chunk(%{agent_kind: nil} = data, _chunk) do
    {data.transcript_events, [], data.transcript_parser_state}
  end

  defp parse_chunk(%{agent_kind: kind, transcript_events: events, transcript_parser_state: state}, chunk) do
    Transcript.append_chunk(events, kind, state, chunk)
  end

  # Flushes any trailing partial-line bytes the per-agent parser buffered when
  # the agent's Port closed (a complete JSON object/event without a final
  # newline would otherwise never surface in the parsed-event view). Mirrors
  # the per-chunk path: trim via the shared helper, and broadcast the drained
  # delta on a fresh seq so a live subscriber sees the last event too.
  # No-op for unregistered adapters (agent_kind: nil).
  @spec finalize_transcript(data()) :: data()
  defp finalize_transcript(%{agent_kind: nil} = data), do: data

  defp finalize_transcript(%{agent_kind: kind, transcript_events: events, transcript_parser_state: state} = data) do
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
