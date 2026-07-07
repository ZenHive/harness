defmodule Harness.Run do
  @moduledoc """
  The supervised lifecycle of one coding-agent job.

  A `Harness.Run` is a `:gen_statem` that owns one rmap task end to end: it
  creates an isolated git worktree, dispatches a headless implementer agent
  into it, commits the agent's work, hands the worktree to a cross-family
  reviewer agent — THE gate — and settles on the reviewer's verdict. It is the
  unit the project's CLAUDE.md calls "one run = one supervised gen_statem".

  ## States

      dispatched  — creating the isolated worktree
      running     — the implementer agent is working in the worktree
      committing  — committing the implementer's work to the run branch
      recovering   — bounded AI recovery for witnessed checkout pollution
      reviewing   — the cross-family reviewer (THE gate) reviews, runs the
                    project's checks itself, fixes inline, writes its verdict
      held        — operator-parked; worktree retained, lifetime timer suspended
      done        — the reviewer approved (terminal)
      failed      — anything else (terminal)

  Each state runs its slow work in a task *monitored, never linked* by the
  gen_statem, so a crashing step surfaces as an event rather than crashing the
  run. `done` and `failed` are terminal: the run delivers a `Harness.Run.Result`
  to its subscriber as `{:harness_run, run_id, result}`, lingers briefly so a
  late `status/1` still resolves, then stops `:normal`.

  ## The gate

  A run is graded by the reviewer AI alone — never by the implementer's exit
  code, self-reported result, or any mechanical check runner inside harness.
  The reviewer gets the worktree, the task spec, the implementer transcript
  tail, the diff stat, and the project's `check_command` hint. It reviews, runs
  the checks itself, fixes inline (its own edits, its own commits), and writes
  `.harness/review.json` (`Harness.Run.Review`). Harness reads that artifact
  mechanically: approve settles `:done`, reject settles `:failed` with the
  reviewer's report. An *unreadable* artifact — missing (the reviewer exited
  without writing it) or malformed (it wrote invalid verdict JSON) — is
  re-prompted ONCE in the same worktree (Task 203, generalized) — a mechanical
  re-issue of the mandatory write, not a re-judgment — before settling
  `{:review_stuck, ...}` on a second unreadable result. A reviewer that never
  spawns or goes idle past its watchdog is *rotated* to the next eligible
  cross-family reviewer (the finite slate carved at route-into-review) before
  settling `{:review_stuck, ...}` — also mechanical: next-candidate selection,
  no content inspected to judge recoverability. Both fallback counts ride onto
  the run record as raw facts.

  Rejection is reserved for degenerate cases — an empty or unusable worktree,
  destructive or fully off-task work. Everything fixable the reviewer fixes and
  approves: a rejection cycle costs two more full agent runs.

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
  one is running, then settle `failed`. The `:running` and `:reviewing` states
  arm idle watchdogs so a silent spawned Port cannot hold a project queue slot
  until the lifetime cap (Tasks 199 and 239). The lifetime budget is a
  last-resort deadline — it force-settles even when the agent run handle never
  arrived (a hung adapter `build_command`/`invoke`). In that race a just-spawned
  OS process whose pid was never received may leak; the boot-time
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

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.Actions
  alias Harness.Run.Recovery
  alias Harness.Run.Result
  alias Harness.Run.Review
  alias Harness.Run.States
  alias Harness.Run.Status
  alias Harness.TokenUsage
  alias Harness.Worktree

  @registry Harness.Run.Registry

  @typedoc "A lifecycle state."
  @type state ::
          :dispatched
          | :running
          | :committing
          | :recovering
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
           started_at: DateTime.t(),
           state_entered_at: %{optional(state() | :recovery_review) => DateTime.t()},
           started_at_ms: integer(),
           total_timeout: timeout() | nil,
           idle_timeout: timeout() | nil,
           implementer_idle_timeout: timeout() | nil,
           progress_timeout: timeout() | nil,
           lifetime_timeout: pos_integer(),
           max_hold_timeout: timeout(),
           terminal_linger: non_neg_integer(),
           reviewer: atom() | module() | [atom() | module()] | nil,
           reviewer_adapter: module() | nil,
           reviewer_candidates: [module()],
           reviewer_adapter_opts: keyword(),
           reviewer_agent_resolver: (module() -> {:ok, atom()} | {:error, term()}),
           reviewer_run: AgentRun.t() | nil,
           recovery_adapter: module() | nil,
           recovery_run: AgentRun.t() | nil,
           recovery_budget: non_neg_integer(),
           recovery_attempts: non_neg_integer(),
           recovery_reason: Result.reason() | nil,
           recovery_outcome: Recovery.outcome() | nil,
           recovery_repaired: String.t() | nil,
           recovery_token_usage: TokenUsage.t(),
           reviewer_spawn_timeout: pos_integer(),
           reviewing_idle_timeout: pos_integer() | nil,
           mem_threshold_kb: pos_integer(),
           mem_sample_interval: pos_integer(),
           review: Review.t() | nil,
           reviewer_outcome: Outcome.t() | nil,
           reviewer_diff_size: non_neg_integer() | nil,
           reviewer_pre_review_sha: String.t() | nil,
           reviewer_reprompt_count: non_neg_integer(),
           reviewer_rotation_count: non_neg_integer(),
           review_only?: boolean(),
           review_only_agent_diff_size: non_neg_integer() | nil,
           implementer_empty_diff?: boolean(),
           hold_requested: false | :graceful | :interrupt,
           hold_reason: :graceful | :interrupt | nil,
           operator_feedback: String.t() | nil,
           in_run_discernment: keyword(),
           substrate_retry: keyword(),
           base_dir: String.t() | nil,
           base_ref: String.t() | nil,
           adapter_opts: keyword(),
           env: %{optional(String.t()) => String.t() | false},
           land_attempt: pos_integer(),
           worktree: Worktree.t() | nil,
           checkout_snapshot: String.t() | nil,
           checkout_pollution_check?: boolean(),
           pollution_allowlist: [String.t()],
           agent_run: AgentRun.t() | nil,
           agent_outcome: Outcome.t() | nil,
           composed_inputs: [AgentAdapter.composed_input()],
           token_usage: TokenUsage.t(),
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
        "{:ok, %Harness.Run.Status{}} carrying state, worktree_path, agent_os_pid, agent_kind, review_verdict, reason. {:error, :not_found} for stopped/unknown runs."
    }
  )

  @spec status(run()) :: {:ok, Status.t()} | {:error, :not_found}
  def status(run), do: status(run, :infinity)

  @doc "Return a status snapshot, bounded by the caller-provided timeout."
  @spec status(run(), timeout()) :: {:ok, Status.t()} | {:error, :not_found | :timeout}
  def status(run, timeout) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :status, timeout)}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
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

    # The project arrives already landing-overlaid: every dispatch path resolves
    # it through `Harness.ProjectRegistry.lookup/1`, the single read boundary that
    # applies the operator's persisted override. The run trusts the effective
    # struct it is handed — it does not re-derive policy (no per-call-site overlay).
    {mem_threshold_kb, mem_sample_interval} = Actions.mem_watchdog_config(opts)

    started_at = DateTime.utc_now(:millisecond)

    data = %{
      run_id: run_id,
      item: item,
      project: project,
      adapter: adapter,
      subscriber: Keyword.get(opts, :subscriber),
      result_store: Keyword.get(opts, :result_store, ResultStore.configured()),
      batch_id: Keyword.get(opts, :batch_id) || run_id,
      requested_model: Actions.requested_model(opts, item, adapter),
      started_at: started_at,
      state_entered_at: %{dispatched: started_at},
      started_at_ms: System.monotonic_time(:millisecond),
      total_timeout: Actions.run_timeout(opts, :total_timeout),
      idle_timeout: Actions.run_timeout(opts, :idle_timeout),
      implementer_idle_timeout: Keyword.get(opts, :implementer_idle_timeout),
      progress_timeout: Keyword.get(opts, :progress_timeout),
      lifetime_timeout: Actions.run_timeout(opts, :lifetime_timeout),
      max_hold_timeout: Actions.run_timeout(opts, :max_hold_timeout),
      terminal_linger: Actions.run_timeout(opts, :terminal_linger),
      reviewer: Keyword.get(opts, :reviewer, project.reviewer || Actions.configured(:reviewer, nil)),
      reviewer_adapter: nil,
      reviewer_candidates: [],
      reviewer_adapter_opts: Keyword.get(opts, :reviewer_adapter_opts, []),
      reviewer_agent_resolver: Keyword.get(opts, :reviewer_agent_resolver, &AgentRegistry.agent_for_module/1),
      reviewer_run: nil,
      recovery_adapter: nil,
      recovery_run: nil,
      recovery_budget: Keyword.get(opts, :recovery_budget, 1),
      recovery_attempts: 0,
      recovery_reason: nil,
      recovery_outcome: nil,
      recovery_repaired: nil,
      recovery_token_usage: TokenUsage.empty(),
      reviewer_spawn_timeout: Actions.run_timeout(opts, :reviewer_spawn_timeout),
      reviewing_idle_timeout: Keyword.get(opts, :reviewing_idle_timeout),
      mem_threshold_kb: mem_threshold_kb,
      mem_sample_interval: mem_sample_interval,
      review: nil,
      reviewer_outcome: nil,
      reviewer_diff_size: nil,
      reviewer_pre_review_sha: nil,
      reviewer_reprompt_count: 0,
      reviewer_rotation_count: 0,
      review_only?: Keyword.get(opts, :review_only?, false),
      review_only_agent_diff_size: Keyword.get(opts, :review_only_agent_diff_size),
      implementer_empty_diff?: false,
      hold_requested: false,
      hold_reason: nil,
      operator_feedback: nil,
      in_run_discernment: Actions.in_run_discernment_opts(opts),
      substrate_retry: Keyword.get(opts, :substrate_retry, []),
      base_dir: Keyword.get(opts, :base_dir),
      base_ref: Keyword.get(opts, :base_ref),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      env: Actions.run_env(project, run_id, Keyword.get(opts, :env, %{})),
      land_attempt: Keyword.get(opts, :land_attempt, 1),
      worktree: nil,
      checkout_snapshot: nil,
      checkout_pollution_check?: Keyword.get(opts, :checkout_pollution_check, false),
      pollution_allowlist: Actions.resolve_pollution_allowlist(project, opts),
      agent_run: nil,
      agent_outcome: nil,
      composed_inputs: [],
      token_usage: TokenUsage.empty(),
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
      agent_kind: Actions.agent_kind_for(adapter),
      transcript_events: [],
      transcript_parser_state: Actions.init_parser_state(adapter)
    }

    {:ok, :dispatched, data,
     [
       {{:timeout, :lifetime}, data.lifetime_timeout, :lifetime},
       {{:timeout, :mem_sample}, data.mem_sample_interval, :mem_sample}
     ]}
  end

  @doc false
  @impl :gen_statem
  @spec terminate(term(), state(), data()) :: term()
  def terminate(_reason, _state, %{result: %Result{}}), do: :ok

  def terminate(reason, state, data) do
    Actions.crash_settle(data, state, reason)
    :ok
  end

  @doc false
  @spec recoverable_code_reload_states() :: [atom()]
  defdelegate recoverable_code_reload_states, to: Actions

  @doc false
  @spec prioritize_reviewers([{atom(), module()}], %{optional(module()) => float()}) :: [{atom(), module()}]
  defdelegate prioritize_reviewers(candidates, rates), to: Actions

  @doc false
  @spec reviewer_dispatchable?(module()) :: boolean()
  defdelegate reviewer_dispatchable?(module), to: Actions

  @doc false
  @spec reviewer_model_available?(data()) :: :ok | {:error, term()}
  defdelegate reviewer_model_available?(data), to: Actions

  @doc false
  @spec implementer_idle_timeout(timeout() | nil) :: timeout()
  defdelegate implementer_idle_timeout(idle), to: Actions

  @doc false
  @spec reviewing_idle_timeout(data()) :: pos_integer()
  defdelegate reviewing_idle_timeout(data), to: Actions

  @doc false
  @spec reviewer_idle_timeout(timeout() | nil) :: timeout()
  defdelegate reviewer_idle_timeout(idle), to: Actions

  @doc false
  @spec discernment_weight_passes?(data(), keyword(), integer()) :: boolean()
  defdelegate discernment_weight_passes?(data, opts, now), to: Actions

  # ── State callbacks — per-state handlers live under Harness.Run.States ────

  @doc false
  @spec dispatched(event(), term(), data()) :: handler_result()
  def dispatched(event_type, event_content, data), do: States.Dispatched.handle(event_type, event_content, data)

  @doc false
  @spec running(event(), term(), data()) :: handler_result()
  def running(event_type, event_content, data), do: States.Running.handle(event_type, event_content, data)

  @doc false
  @spec committing(event(), term(), data()) :: handler_result()
  def committing(event_type, event_content, data), do: States.Committing.handle(event_type, event_content, data)

  @doc false
  @spec recovering(event(), term(), data()) :: handler_result()
  def recovering(event_type, event_content, data), do: States.Recovering.handle(event_type, event_content, data)

  @doc false
  @spec reviewing(event(), term(), data()) :: handler_result()
  def reviewing(event_type, event_content, data), do: States.Reviewing.handle(event_type, event_content, data)

  @doc false
  @spec held(event(), term(), data()) :: handler_result()
  def held(event_type, event_content, data), do: States.Held.handle(event_type, event_content, data)

  @doc false
  @spec done(event(), term(), data()) :: handler_result()
  def done(event_type, event_content, data), do: States.Done.handle(event_type, event_content, data)

  @doc false
  @spec failed(event(), term(), data()) :: handler_result()
  def failed(event_type, event_content, data), do: States.Failed.handle(event_type, event_content, data)
end
