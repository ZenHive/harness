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

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentKPI
  alias Harness.AgentRegistry
  alias Harness.AuditReview
  alias Harness.Config
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
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
  alias Harness.Run.Reflex
  alias Harness.Run.Result
  alias Harness.Run.RetryPolicy
  alias Harness.Run.Review
  alias Harness.Run.Status
  alias Harness.Text
  alias Harness.TokenUsage
  alias Harness.TokenUsage.GrokSession
  alias Harness.Worktree
  alias Harness.Worktree.Isolation
  alias Harness.Worktree.Reaper
  alias Oban.Job

  require Logger

  @registry Harness.Run.Registry
  @task_supervisor Harness.Run.TaskSupervisor

  @semantic_diff_max_bytes 80_000
  @reviewer_transcript_tail_bytes 40_000
  @default_discernment_sample_interval_ms 300_000
  @default_discernment_min_weight 6
  @default_discernment_long_running_ms 600_000
  @default_discernment_min_transcript_bytes 1
  # Recent run records sampled to score reviewer rejection rates for cross-family
  # reviewer selection — bounds the per-run store read (newest-first).
  @reviewer_rejection_sample 500
  # Idle-window floor for the reviewing phase. The reviewer runs the project's
  # full check_command (`cargo test`, `mix precommit.full`) itself — a stretch
  # that streams nothing for minutes while the check compiles/runs, so the
  # implementer-grade 5-min idle default can fire mid-check and lose the run to
  # :review_stuck before the verdict is written (Task 181, rmap run-…-b4d8528e:
  # reviewer fixed 274 lines, then idle-killed at ~15.8 min before writing
  # review.json). Floor the reviewing idle window at 10 min so a single silent
  # check can't trip it; an explicit higher idle_timeout still wins. Well under
  # the 90-min lifetime cap, which remains the real backstop.
  @reviewer_idle_floor 600_000

  # Idle-window floor for the implementer phase (Task 239). Implementers also
  # run long silent compile/test/dialyzer commands, so the mechanical idle
  # watchdog must be high enough that one silent check run does not lose the
  # attempt. An explicit higher idle_timeout still wins; lower/nil values are
  # raised to the same 10-min floor used by reviewers.
  @implementer_idle_floor 600_000

  # Missing-verdict re-prompt budget (Task 203). The reviewer's one mandatory
  # mechanical act is writing `.harness/review.json`; a reviewer that finishes
  # the review but exits a hair before that write loses the ENTIRE run (full
  # implementer + reviewer spend) to a discard + re-dispatch (rmap
  # run-…-f3ebb30a: a 214-line review, reviewer exited 0 without the verdict).
  # On a MISSING verdict only, re-invoke the SAME reviewer once in the SAME
  # worktree with a terse "write the verdict now" nudge before failing as
  # :review_stuck. This is MECHANICAL — re-issuing a flush of an artifact the
  # reviewer was contractually required to write. Harness interprets no work,
  # classifies no outcome, makes no approve/reject decision: the verdict still
  # lives entirely in whatever the re-invoked reviewer writes. It does not
  # reopen the agent-gate "machinery interprets outcomes" door (CLAUDE.md) — a
  # bounded retry of a mechanical write is the same class as retrying a failed
  # `git push`. Bounded to exactly one retry; a second miss fails as before.
  @reviewer_reprompt_limit 1

  # Per-run memory watchdog (Task 200). The reviewer AI runs the project's
  # check_command itself; harness Ports the agent CLI and the agent forks `mix`/
  # `cargo`/… as its own descendants — a tree harness spawns but never bounded.
  # On 2026-06-04 an "onchain" check beam ran away to ~27 GB and OOM'd the host
  # twice (kernel watchdog panic + jetsam). Sample the spawned tree's resident
  # memory on this interval and force-kill it past the ceiling, settling :failed.
  @default_mem_threshold_kb 6 * 1024 * 1024
  @default_mem_sample_interval 5_000
  # Agent-gate substrate: in-run agents must not reach GitHub origin on their
  # own initiative. Scrubbing tokens alone is not enough because `gh` can read
  # stored auth from hosts.yml, so invocations also point GH_CONFIG_DIR at a
  # run-local config directory.
  @github_auth_env_scrubs ["GH_TOKEN", "GITHUB_TOKEN"]
  @gh_config_dir Path.join([".harness", "gh-config"])

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

    # The project arrives already landing-overlaid: every dispatch path resolves
    # it through `Harness.ProjectRegistry.lookup/1`, the single read boundary that
    # applies the operator's persisted override. The run trusts the effective
    # struct it is handed — it does not re-derive policy (no per-call-site overlay).
    {mem_threshold_kb, mem_sample_interval} = mem_watchdog_config(opts)

    data = %{
      run_id: run_id,
      item: item,
      project: project,
      adapter: adapter,
      subscriber: Keyword.get(opts, :subscriber),
      result_store: Keyword.get(opts, :result_store, ResultStore.configured()),
      batch_id: Keyword.get(opts, :batch_id) || run_id,
      requested_model: Keyword.get(opts, :requested_model) || item.model || Config.agent_model(item.agent),
      started_at_ms: System.monotonic_time(:millisecond),
      total_timeout: run_timeout(opts, :total_timeout),
      idle_timeout: run_timeout(opts, :idle_timeout),
      implementer_idle_timeout: Keyword.get(opts, :implementer_idle_timeout),
      progress_timeout: Keyword.get(opts, :progress_timeout),
      lifetime_timeout: run_timeout(opts, :lifetime_timeout),
      max_hold_timeout: run_timeout(opts, :max_hold_timeout),
      terminal_linger: run_timeout(opts, :terminal_linger),
      reviewer: Keyword.get(opts, :reviewer, project.reviewer || configured(:reviewer, nil)),
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
      reviewer_spawn_timeout: run_timeout(opts, :reviewer_spawn_timeout),
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
      in_run_discernment: in_run_discernment_opts(opts),
      substrate_retry: Keyword.get(opts, :substrate_retry, []),
      base_dir: Keyword.get(opts, :base_dir),
      base_ref: Keyword.get(opts, :base_ref),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      env: scrub_github_auth_env(Keyword.get(opts, :env, %{})),
      land_attempt: Keyword.get(opts, :land_attempt, 1),
      worktree: nil,
      checkout_snapshot: nil,
      checkout_pollution_check?: Keyword.get(opts, :checkout_pollution_check, false),
      pollution_allowlist: resolve_pollution_allowlist(project, opts),
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
      agent_kind: agent_kind_for(adapter),
      transcript_events: [],
      transcript_parser_state: init_parser_state(adapter)
    }

    {:ok, :dispatched, data,
     [
       {{:timeout, :lifetime}, data.lifetime_timeout, :lifetime},
       {{:timeout, :mem_sample}, data.mem_sample_interval, :mem_sample}
     ]}
  end

  # ── State: dispatched — carve the isolated worktree ──────────────────────

  @doc false
  @spec dispatched(event(), term(), data()) :: handler_result()
  def dispatched(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:dispatched, data))
    task = start_task(fn -> Worktree.create(data.project, worktree_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  # The worktree exists — warm it, then hand it to the agent. Warming is a
  # mechanical byte-copy of the parent checkout's gitignored build artifacts
  # (deps/_build/PLT) into the fresh tree, so the implementer doesn't cold-fetch
  # deps and the reviewer doesn't cold-compile + cold-build the dialyzer PLT. It
  # is a pure optimization, never a gate — `warm/2` always returns `:ok`; a copy
  # that fails just means the agent cold-builds that path. (Mechanics, not
  # judgment: copying bytes — the mantra-clean half of the warm step the
  # agent-gate rebuild deleted along with Harness.Verification.)
  def dispatched(:info, {ref, {:ok, %Worktree{} = worktree}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil, worktree: worktree}

    with :ok <- Worktree.activate(worktree),
         :ok <- Worktree.warm(worktree, warm_paths: data.project.warm_paths),
         :ok <- maybe_validate_implementer_isolation(data) do
      # Crash reaper (Task 185): once the worktree is live, a hard crash of this
      # gen_statem before settle would leak it; the reaper monitors us and reaps
      # on an abnormal :DOWN. settle/2 untracks once the worktree is finalized.
      Reaper.track(self(), data.run_id, worktree.path, worktree.repo)
      route_after_dispatch(data)
    else
      {:error, {:worktree_isolation_unsupported, _adapter, _message} = reason} ->
        fail(data, {:agent_spawn_failed, reason})

      {:error, reason} ->
        fail(data, {:worktree_failed, reason})
    end
  end

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

  # ── State: running — the implementer agent works in the worktree ──────────

  @doc false
  @spec running(event(), term(), data()) :: handler_result()
  # Entering `running` always means a fresh agent is about to spawn — the first
  # dispatch, or an operator-steered resume. `agent_run` / `agent_outcome` are
  # reset so a stale handle from a prior attempt never misleads the cancel-defer
  # logic or a `status/1` snapshot.
  def running(:enter, _old_state, data) do
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
        {:keep_state, data, [{:state_timeout, running_idle_timeout(data), :implementer_idle_timeout}]}
    end
  end

  def running(:state_timeout, :implementer_idle_timeout, %{agent_run: %AgentRun{} = run} = data) do
    terminate_agent(data)
    cancel_task(data.task)
    cancel_task(data.discernment_task)

    outcome = %Outcome{run: run, output: data.transcript, exit_status: nil, kind: {:timed_out, :idle}}

    settle_implementer_outcome(%{data | task: nil, discernment_task: nil}, outcome)
  end

  def running(:state_timeout, :implementer_idle_timeout, _data), do: :keep_state_and_data

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

    settle_implementer_outcome(%{data | task: nil, discernment_task: nil}, outcome)
  end

  def running(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    cancel_task(data.discernment_task)
    fail(%{data | task: nil, discernment_task: nil}, {:agent_spawn_failed, reason})
  end

  def running(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    cancel_task(data.discernment_task)
    data = %{data | task: nil, discernment_task: nil}

    case checkout_pollution_reason(data) do
      nil -> fail(data, {:driver_crashed, reason})
      pollution_reason -> recover_checkout_pollution(data, pollution_reason)
    end
  end

  def running(event_type, event_content, data) do
    handle_common(event_type, event_content, :running, data)
  end

  # ── State: committing — capture the implementer's work on the run branch ──

  @doc false
  @spec committing(event(), term(), data()) :: handler_result()
  def committing(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:committing, data))
    worktree = data.worktree
    message = commit_message(data)
    task = start_task(fn -> commit_worktree(data, worktree, message) end)
    {:keep_state, %{data | task: task}}
  end

  def committing(:info, {ref, {:ok, :committed, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    route_to_review(%{data | task: nil, agent_diff_size: diff_size})
  end

  # An empty diff is never disposed of here — what it *means* (already
  # implemented vs nothing happened) is the reviewer's judgment, not a
  # disposition branch. The reviewer gets the empty-diff context in its prompt
  # and decides: approve (already implemented / fixed it itself) or reject
  # (nothing to salvage).
  def committing(:info, {ref, {:ok, :no_changes, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    route_to_review(%{data | task: nil, agent_diff_size: diff_size, implementer_empty_diff?: true})
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

  # ── State: recovering — bounded AI seam before checkout-pollution failure ──

  @doc false
  @spec recovering(event(), term(), data()) :: handler_result()
  def recovering(:enter, _old_state, data) do
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

  def recovering(:info, {:recovery_handle, %AgentRun{} = run}, data) do
    {:keep_state, %{data | recovery_run: run}, [{:state_timeout, reviewing_idle_timeout(data), :recovery_idle_timeout}]}
  end

  def recovering(:state_timeout, :recovery_spawn_timeout, %{recovery_run: nil} = data) do
    fail_recovery_dead(data, "Recovery agent never spawned within #{data.reviewer_spawn_timeout}ms.")
  end

  def recovering(:state_timeout, :recovery_spawn_timeout, _data), do: :keep_state_and_data

  def recovering(:state_timeout, :recovery_idle_timeout, data) do
    fail_recovery_dead(data, "Recovery made no progress within #{reviewing_idle_timeout(data)}ms.")
  end

  def recovering(
        :info,
        {ref, {:ok, %{outcome: %Outcome{} = outcome, recovery: recovery}}},
        %{task: %Task{ref: ref}} = data
      ) do
    Process.demonitor(ref, [:flush])

    data =
      data
      |> clear_recovery_run()
      |> Map.put(:task, nil)
      |> accumulate_recovery_token_usage(outcome)

    settle_recovery(data, recovery)
  end

  def recovering(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    terminate_recovery(data)
    fail_recovery_dead(%{data | task: nil}, "Recovery failed to run: #{inspect(reason)}")
  end

  def recovering(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    terminate_recovery(data)
    fail_recovery_dead(%{data | task: nil}, "Recovery crashed: #{inspect(reason)}")
  end

  def recovering(event_type, event_content, data) do
    handle_common(event_type, event_content, :recovering, data)
  end

  # ── State: reviewing — the cross-family reviewer is THE gate ─────────────

  @doc false
  @spec reviewing(event(), term(), data()) :: handler_result()
  def reviewing(:enter, _old_state, data) do
    case ensure_reviewer_model_available(data) do
      :ok ->
        RunFeed.broadcast_update(status_snapshot(:reviewing, data))
        parent = self()
        task = start_task(fn -> run_reviewer(data, parent) end)

        {:keep_state, %{data | task: task, agent_run: nil, reviewer_run: nil},
         [{:state_timeout, data.reviewer_spawn_timeout, :reviewer_spawn_timeout}]}

      {:error, reason} ->
        {:next_state, :failed, %{data | reason: reason}}
    end
  end

  def reviewing(:info, {:reviewer_handle, %AgentRun{} = run}, data) do
    {:keep_state, %{data | reviewer_run: run}, [{:state_timeout, reviewing_idle_timeout(data), :reviewer_idle_timeout}]}
  end

  def reviewing(:state_timeout, :reviewer_spawn_timeout, %{reviewer_run: nil} = data) do
    rotate_or_fail_review(data, reviewer_spawn_timeout_report(data))
  end

  def reviewing(:state_timeout, :reviewer_spawn_timeout, _data), do: :keep_state_and_data

  def reviewing(:state_timeout, :reviewer_idle_timeout, data) do
    rotate_or_fail_review(data, reviewer_idle_timeout_report(data))
  end

  def reviewing(
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

  def reviewing(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    terminate_reviewer(data)
    report = "Reviewer failed to run: #{inspect(reason)}"
    {:next_state, :failed, clear_reviewer_run(%{data | task: nil, reason: {:review_stuck, report}})}
  end

  def reviewing(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    terminate_reviewer(data)
    report = "Reviewer crashed: #{inspect(reason)}"
    {:next_state, :failed, clear_reviewer_run(%{data | task: nil, reason: {:review_stuck, report}})}
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

  # State-agnostic so a chunk that lands during `:committing` / `:reviewing` /
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

    result = maybe_sample_in_run_discernment(state, data)
    result = rearm_running_idle(state, data, result)
    rearm_reviewing_idle(state, data, result)
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

  defp handle_common({:timeout, :mem_sample}, :mem_sample, state, _data) when state in [:done, :failed, :held] do
    :keep_state_and_data
  end

  defp handle_common({:timeout, :mem_sample}, :mem_sample, _state, data) do
    check_memory(data)
  end

  # Stale task messages (a result or DOWN from a task already consumed or
  # killed) and any other unrecognised info — ignored.
  defp handle_common(:info, _content, _state, _data), do: :keep_state_and_data

  # Defensive catch-all for any other event type.
  defp handle_common(_type, _content, _state, _data), do: :keep_state_and_data

  # ── Cancellation & settling ───────────────────────────────────────────────

  @spec settle_implementer_outcome(data(), Outcome.t()) :: handler_result()
  defp settle_implementer_outcome(data, %Outcome{} = outcome) do
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
        route_reflex_halt(data, reason)
        fail(data, {:reflex_halted, reason})

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
  @spec do_hold(data(), :graceful | :interrupt, [:gen_statem.action()]) :: handler_result()
  defp do_hold(data, mode, extra_actions \\ []) do
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

  @spec do_resume(data(), :gen_statem.from()) :: handler_result()
  defp do_resume(data, from) do
    data = %{data | hold_reason: nil}

    {:next_state, :running, data,
     [
       {:reply, from, :ok},
       {{:timeout, :lifetime}, data.lifetime_timeout, :lifetime},
       {{:timeout, :mem_sample}, data.mem_sample_interval, :mem_sample}
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
  @spec force_settle_lifetime(data()) :: handler_result()
  defp force_settle_lifetime(data) do
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
  @spec fail(data(), Result.reason()) :: handler_result()
  defp fail(data, reason) do
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
  @spec check_memory(data()) :: handler_result()
  defp check_memory(data) do
    case runaway_tree(data) do
      {role, os_pid, rss_kb} ->
        fail_memory_runaway(data, role, os_pid, rss_kb)

      nil ->
        {:keep_state_and_data, [{{:timeout, :mem_sample}, data.mem_sample_interval, :mem_sample}]}
    end
  end

  @type runaway_role :: :agent | :recovery | :reviewer

  @spec runaway_tree(data()) :: {runaway_role(), non_neg_integer(), non_neg_integer()} | nil
  defp runaway_tree(data) do
    candidates = [
      {:agent, data.agent_run},
      {:recovery, data.recovery_run},
      {:reviewer, data.reviewer_run}
    ]

    Enum.find_value(candidates, fn {role, run} ->
      over_threshold(role, run, data.mem_threshold_kb)
    end)
  end

  @spec over_threshold(runaway_role(), AgentRun.t() | nil, pos_integer()) ::
          {runaway_role(), non_neg_integer(), non_neg_integer()} | nil
  defp over_threshold(_role, nil, _threshold), do: nil
  defp over_threshold(_role, %AgentRun{os_pid: nil}, _threshold), do: nil

  defp over_threshold(role, %AgentRun{os_pid: os_pid}, threshold) do
    rss_kb = MemoryGuard.tree_rss_kb(os_pid)
    if rss_kb > threshold, do: {role, os_pid, rss_kb}
  end

  # Force-kills the runaway process tree (the descendant grandchild a plain
  # adapter.terminate/1 would orphan) BEFORE the adapter teardown closes its
  # Port — while the port is open the os_pid still names this run's tree
  # (mirrors the OSProcess.kill ordering note) — then settles :failed.
  @spec fail_memory_runaway(data(), runaway_role(), non_neg_integer(), non_neg_integer()) ::
          handler_result()
  defp fail_memory_runaway(data, role, os_pid, rss_kb) do
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

  @spec terminate_reviewer(data()) :: :ok
  defp terminate_reviewer(%{reviewer_run: nil}), do: :ok

  defp terminate_reviewer(%{reviewer_run: %AgentRun{} = run, reviewer_adapter: adapter}) when is_atom(adapter) do
    adapter.terminate(run)
    :ok
  end

  @spec terminate_recovery(data()) :: :ok
  defp terminate_recovery(%{recovery_run: nil}), do: :ok

  defp terminate_recovery(%{recovery_run: %AgentRun{} = run, recovery_adapter: adapter}) when is_atom(adapter) do
    adapter.terminate(run)
    :ok
  end

  @spec clear_recovery_run(data()) :: data()
  defp clear_recovery_run(data), do: %{data | recovery_run: nil}

  @spec recover_checkout_pollution(data(), Result.reason()) :: handler_result()
  defp recover_checkout_pollution(%{recovery_attempts: attempts, recovery_budget: budget} = data, reason)
       when attempts < budget do
    {:next_state, :recovering, %{data | reason: reason, recovery_reason: reason}}
  end

  defp recover_checkout_pollution(data, reason), do: {:next_state, :failed, %{data | reason: reason}}

  @spec fail_recovery_dead(data(), String.t()) :: handler_result()
  defp fail_recovery_dead(data, report) do
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

  @spec settle_recovery(data(), {:ok, Recovery.t()} | {:error, Recovery.error()}) :: handler_result()
  defp settle_recovery(data, {:ok, %Recovery{outcome: :repaired} = recovery}) do
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

  defp settle_recovery(data, {:ok, %Recovery{outcome: :dead} = recovery}) do
    fail_recovery_dead(%{data | recovery_repaired: recovery.repaired}, recovery.report)
  end

  defp settle_recovery(data, {:error, reason}) do
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
  @spec rotate_or_fail_review(data(), String.t()) :: handler_result()
  defp rotate_or_fail_review(%{reviewer_candidates: [next | rest]} = data, _report) do
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

  defp rotate_or_fail_review(data, report), do: fail_review_stuck(data, report)

  @spec fail_review_stuck(data(), String.t()) :: handler_result()
  defp fail_review_stuck(data, report) do
    # Terminate the reviewer (SIGKILL via its captured os_pid) BEFORE tearing
    # down the task that owns its Port — closing the port first could reap/race
    # the pid (Task 199 audit).
    terminate_reviewer(data)
    cancel_task(data.task)
    {:next_state, :failed, clear_reviewer_run(%{data | task: nil, reason: {:review_stuck, report}})}
  end

  @spec clear_reviewer_run(data()) :: data()
  defp clear_reviewer_run(data), do: %{data | reviewer_run: nil}

  # Re-arm the idle watchdog on implementer progress — but ONLY once the
  # implementer handle is captured. Before the handle arrives there is no OS pid
  # to reap directly, so the lifetime timeout remains the backstop.
  @spec rearm_running_idle(state(), data(), handler_result()) :: handler_result()
  defp rearm_running_idle(:running, %{agent_run: %AgentRun{}} = data, {:keep_state, next_data}) do
    {:keep_state, next_data, [{:state_timeout, running_idle_timeout(data), :implementer_idle_timeout}]}
  end

  defp rearm_running_idle(_state, _data, result), do: result

  # Re-arm the idle watchdog on reviewer progress — but ONLY once the reviewer
  # handle is captured (reviewer_run set). Before the handle arrives the spawn
  # watchdog owns the single state_timeout; a stray/early transcript chunk must
  # not replace it with the longer idle window (Task 199 audit).
  @spec rearm_reviewing_idle(state(), data(), handler_result()) :: handler_result()
  defp rearm_reviewing_idle(:reviewing, %{reviewer_run: %AgentRun{}} = data, {:keep_state, next_data}) do
    {:keep_state, next_data, [{:state_timeout, reviewing_idle_timeout(data), :reviewer_idle_timeout}]}
  end

  defp rearm_reviewing_idle(_state, _data, result), do: result

  @spec reviewer_spawn_timeout_report(data()) :: String.t()
  defp reviewer_spawn_timeout_report(data) do
    "Reviewer agent never spawned within #{data.reviewer_spawn_timeout}ms."
  end

  @spec reviewer_idle_timeout_report(data()) :: String.t()
  defp reviewer_idle_timeout_report(data) do
    "Reviewer made no progress within #{reviewing_idle_timeout(data)}ms."
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
    if terminal_state == :failed, do: maybe_capture_structured_failure(data)
    result = build_result(data, terminal_state)
    data = %{data | result: result}
    persist_run_record(data, result)
    finish_worktree(data.worktree, terminal_state)
    # Worktree is finalized (removed on success / retained on failure) — stop the
    # crash reaper from monitoring this settled run.
    Reaper.untrack(data.run_id)
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
  @spec maybe_enqueue_landing(data(), Result.state()) :: :ok
  defp maybe_enqueue_landing(
         %{reason: :approved, project: %Project{landing_policy: :auto, target_branch: tb} = project} = data,
         :done
       )
       when is_binary(tb) and tb != "" do
    %{
      "project_name" => project.name,
      "run_id" => data.run_id,
      "task_id" => to_string(data.item.id),
      "agent" => to_string(data.item.agent),
      "reviewer" => reviewer_agent_name(data.reviewer_adapter),
      "branch" => "harness/" <> data.run_id,
      "land_attempt" => data.land_attempt
    }
    |> LanderWorker.new_for_project(project)
    |> HarnessOban.insert()
    |> log_landing_enqueue(data.run_id)
  end

  defp maybe_enqueue_landing(_data, _terminal_state), do: :ok

  # The reviewer's agent-family name, threaded through the landing job so the
  # post-merge audit can pick a third family (∉ {implementer, reviewer}).
  @spec reviewer_agent_name(module() | nil) :: String.t() | nil
  defp reviewer_agent_name(nil), do: nil

  defp reviewer_agent_name(reviewer_adapter) do
    case AgentRegistry.agent_for_module(reviewer_adapter) do
      {:ok, agent} -> to_string(agent)
      {:error, _reason} -> nil
    end
  end

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
      review: data.review,
      reviewer_outcome: data.reviewer_outcome,
      worktree_path: data.worktree && data.worktree.path,
      reviewer_adapter: data.reviewer_adapter,
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

  @spec accumulate_recovery_token_usage(data(), Outcome.t()) :: data()
  defp accumulate_recovery_token_usage(data, %Outcome{output: output}) do
    attempt = TokenUsage.parse(agent_kind_for(data.recovery_adapter), output)
    %{data | recovery_token_usage: TokenUsage.add(data.recovery_token_usage, attempt)}
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
      reviewer_adapter: agent_kind_for(data.reviewer_adapter),
      recovery_adapter: agent_kind_for(data.recovery_adapter),
      review_verdict: data.review && data.review.verdict,
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
  # loop — whatever the implementer leaves behind is the reviewer's to judge.
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
      model: data.requested_model,
      permission_mode: :autonomous,
      adapter_opts: data.adapter_opts,
      env: in_run_env(data)
    }
  end

  @spec in_run_env(data()) :: %{optional(String.t()) => String.t() | false}
  defp in_run_env(%{env: env, worktree: %Worktree{path: path}}) do
    env
    |> Map.put("GH_CONFIG_DIR", Path.join(path, @gh_config_dir))
    |> Harness.RmapPath.ensure_agent_env()
  end

  @spec scrub_github_auth_env(%{optional(String.t()) => String.t() | false}) :: %{
          optional(String.t()) => String.t() | false
        }
  defp scrub_github_auth_env(env) when is_map(env) do
    Enum.reduce(@github_auth_env_scrubs, env, fn key, acc -> Map.put(acc, key, false) end)
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
  defp operator_steer_prompt(%{operator_feedback: feedback}) when is_binary(feedback) do
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
  @spec route_to_review(data()) :: handler_result()
  defp route_to_review(data) do
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

  @spec route_after_dispatch(data()) :: handler_result()
  defp route_after_dispatch(%{review_only?: true} = data) do
    diff_size = data.review_only_agent_diff_size || 0

    data
    |> Map.put(:agent_diff_size, diff_size)
    |> Map.put(:implementer_empty_diff?, diff_size == 0)
    |> route_to_review()
  end

  defp route_after_dispatch(data), do: {:next_state, :running, data}

  @spec maybe_validate_implementer_isolation(data()) ::
          :ok | {:error, {:worktree_isolation_unsupported, module(), String.t()}}
  defp maybe_validate_implementer_isolation(%{review_only?: true}), do: :ok

  defp maybe_validate_implementer_isolation(data), do: Isolation.validate(data.adapter)

  # The verdict artifact is read mechanically — approve settles :done, reject
  # settles :failed with the reviewer's report, an unreadable artifact settles
  # :failed as review_stuck. What the work MEANS was the reviewer's judgment;
  # this function only routes on what it wrote.
  @spec settle_review(data(), {:ok, Review.t()} | {:error, Review.error()}) :: handler_result()
  defp settle_review(data, {:ok, %Review{verdict: :approve} = review}) do
    {:next_state, :done, clear_operator_steer(%{data | review: review, reason: :approved})}
  end

  defp settle_review(data, {:ok, %Review{verdict: :reject} = review}) do
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
  defp settle_review(%{reviewer_reprompt_count: count} = data, {:error, reason}) when count < @reviewer_reprompt_limit do
    Logger.info(
      "harness run: reviewer verdict unreadable (#{inspect(reason)}) for #{data.run_id} — " <>
        "re-prompting once (attempt #{count + 1})"
    )

    {:repeat_state, %{data | reviewer_reprompt_count: count + 1, task: nil}}
  end

  defp settle_review(data, {:error, :missing}) do
    report = "Reviewer wrote no #{Review.artifact_path()} verdict artifact."
    {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
  end

  defp settle_review(data, {:error, {:malformed, detail}}) do
    report = "Reviewer verdict artifact is malformed: #{inspect(detail)}"
    {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
  end

  # Resolves the ordered cross-family reviewer set for a run. The head is the
  # primary reviewer; the tail is the rotation fallback the reviewer-timeout
  # path (`rotate_or_fail_review/2`) draws from. Auto-selection returns the whole
  # prioritized registry slate; an explicit pin returns a one-element list; an
  # explicit list is an operator-supplied rotation order (each element validated
  # cross-family + dispatchable). Empty ⇒ `:review_stuck`.
  @spec select_reviewers(data()) :: {:ok, [module(), ...]} | {:error, term()}
  defp select_reviewers(%{reviewer: nil} = data) do
    case auto_reviewer_modules(data) do
      [] -> {:error, {:no_cross_family_reviewer, data.item.agent}}
      modules -> {:ok, modules}
    end
  end

  defp select_reviewers(%{reviewer: reviewers} = data) when is_list(reviewers) do
    resolve_reviewer_list(data, reviewers)
  end

  defp select_reviewers(%{reviewer: reviewer} = data) do
    with {:ok, module} <- resolve_single_reviewer(data, reviewer), do: {:ok, [module]}
  end

  # The full prioritized cross-family slate from the registry — every installed,
  # reviewer-eligible agent that is not the implementer's family, ordered by
  # soft availability and historical rejection rate. The list is the rotation
  # order on a reviewer timeout, not just the single auto-pick.
  @spec auto_reviewer_modules(data()) :: [module()]
  defp auto_reviewer_modules(data) do
    implementer = data.item.agent

    AgentRegistry.agents()
    |> Enum.reject(fn {agent, _module} -> agent == implementer end)
    |> Enum.filter(fn {_agent, module} -> reviewer_dispatchable?(module) end)
    |> prioritize_reviewers(reviewer_rejection_rates())
    |> Enum.map(fn {_agent, module} -> module end)
  end

  # An explicit reviewer rotation order: resolve + validate each in turn, failing
  # fast on the first invalid pin (mirrors the single-explicit refusal semantics).
  @spec resolve_reviewer_list(data(), [atom() | module()]) :: {:ok, [module(), ...]} | {:error, term()}
  defp resolve_reviewer_list(data, reviewers) do
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

  @spec resolve_single_reviewer(data(), atom() | module()) :: {:ok, module()} | {:error, term()}
  defp resolve_single_reviewer(data, reviewer) do
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
  @spec reviewer_rejection_rates() :: %{optional(module()) => float()}
  defp reviewer_rejection_rates do
    case ResultStore.list_run_records(limit: @reviewer_rejection_sample) do
      {:ok, records} ->
        records
        |> AgentKPI.aggregate_reviewer_rejections()
        |> Map.new(fn {module, metrics} -> {module, metrics.rejection_rate} end)

      _error ->
        %{}
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

  @spec availability_rank(module()) :: 0 | 1
  defp availability_rank(module), do: if(AgentRegistry.available?(module), do: 0, else: 1)

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
  @spec reviewer_eligible?(module()) :: boolean()
  defp reviewer_eligible?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> AgentSettings.reviewer_eligible?(agent)
      {:error, _reason} -> true
    end
  end

  @spec explicit_reviewer_dispatchable?(module()) :: boolean()
  defp explicit_reviewer_dispatchable?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, _agent} -> reviewer_dispatchable?(module)
      {:error, _reason} -> AgentRegistry.available?(module)
    end
  end

  @spec run_recovery(data(), pid()) ::
          {:ok, %{outcome: Outcome.t(), recovery: {:ok, Recovery.t()} | {:error, Recovery.error()}}}
          | {:error, term()}
  defp run_recovery(%{recovery_adapter: adapter} = data, parent) when is_atom(adapter) do
    with {:ok, %Outcome{} = outcome} <-
           run_driver(data, adapter, recovery_invocation(data), recovery_driver_opts(data, parent)) do
      {:ok, %{outcome: outcome, recovery: Recovery.read(data.worktree.path)}}
    end
  end

  @spec recovery_invocation(data()) :: Invocation.t()
  defp recovery_invocation(data) do
    repo_path = Project.repo_path(data.project)

    %Invocation{
      prompt: Recovery.prompt(recovery_context(data, repo_path)),
      cwd: data.worktree.path,
      task_id: "#{data.item.id}-recovery",
      model: data.requested_model,
      permission_mode: :autonomous,
      adapter_opts: data.reviewer_adapter_opts,
      env: Map.put(in_run_env(data), "HARNESS_RECOVERY_REPO", repo_path)
    }
  end

  @spec recovery_context(data(), String.t()) :: Recovery.context()
  defp recovery_context(data, repo_path) do
    %{
      reason: data.recovery_reason,
      repo_path: repo_path,
      git_status: git_status(data.worktree.path),
      transcript_tail: transcript_tail(data.transcript),
      check_output: recovery_check_output(data.recovery_reason, repo_path)
    }
  end

  @spec recovery_check_output(Result.reason() | nil, String.t()) :: String.t()
  defp recovery_check_output({:checkout_polluted, status}, _repo_path) when is_binary(status), do: status
  defp recovery_check_output(_reason, repo_path), do: git_status(repo_path)

  @spec git_status(String.t()) :: String.t()
  defp git_status(path) do
    case Git.run(["status", "--porcelain"], path) do
      {:ok, status} -> status
      {:error, reason} -> "git status failed: #{inspect(reason)}"
    end
  end

  @spec recovery_driver_opts(data(), pid()) :: keyword()
  defp recovery_driver_opts(data, parent) do
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
  @spec run_reviewer(data(), pid()) ::
          {:ok,
           %{
             outcome: Outcome.t(),
             reviewer_diff_size: non_neg_integer(),
             review: {:ok, Review.t()} | {:error, Review.error()}
           }}
          | {:error, term()}
  defp run_reviewer(data, parent) do
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
  @spec measure_reviewer_diff(data(), String.t()) :: non_neg_integer()
  defp measure_reviewer_diff(data, pre_review_sha) do
    case Worktree.diff_size_since(data.worktree, pre_review_sha) do
      {:ok, diff_size} ->
        diff_size

      {:error, reason} ->
        Logger.warning("harness run: reviewer diff measurement failed for #{data.run_id}: #{inspect(reason)}")
        0
    end
  end

  @spec reviewer_invocation(data()) :: Invocation.t()
  defp reviewer_invocation(data) do
    %Invocation{
      prompt: reviewer_invocation_prompt(data),
      cwd: data.worktree.path,
      task_id: "#{data.item.id}-review",
      model: reviewer_model(data),
      permission_mode: :autonomous,
      adapter_opts: data.reviewer_adapter_opts,
      env: in_run_env(data)
    }
  end

  # The reviewer has no task-pin model axis (the task's `model` pins only the
  # implementer), so it resolves from the selected reviewer adapter's agent:
  # reviewer override > shared per-agent default > CLI ambient default.
  @spec reviewer_model(data()) :: String.t() | nil
  defp reviewer_model(%{reviewer_adapter: reviewer_adapter, reviewer_agent_resolver: resolver})
       when is_atom(reviewer_adapter) and not is_nil(reviewer_adapter) and is_function(resolver, 1) do
    case resolver.(reviewer_adapter) do
      {:ok, agent} -> Config.reviewer_model(agent)
      {:error, _reason} -> nil
    end
  end

  defp reviewer_model(_data), do: nil

  @doc false
  @spec reviewer_model_available?(data()) :: :ok | {:error, term()}
  def reviewer_model_available?(%{reviewer_adapter: reviewer_adapter} = data) when is_atom(reviewer_adapter) do
    ensure_reviewer_model_available(data)
  end

  @spec ensure_reviewer_model_available(data()) :: :ok | {:error, term()}
  defp ensure_reviewer_model_available(%{reviewer_adapter: reviewer_adapter}) do
    case AgentRegistry.agent_for_module(reviewer_adapter) do
      {:ok, agent} ->
        model = reviewer_model(reviewer_adapter)

        if ModelAvailability.available?(agent, model) do
          :ok
        else
          {:error, {:unavailable, agent, model, available: ModelAvailability.list_available_ids(agent)}}
        end

      {:error, _} ->
        :ok
    end
  end

  @spec maybe_capture_structured_failure(data()) :: :ok
  defp maybe_capture_structured_failure(%{adapter: adapter, reason: reason} = data) when is_atom(adapter) do
    case ModelAvailability.structured_quota_signal(reason) do
      {:ok, _seconds, _model} ->
        :ok = AgentRegistry.mark_unavailable(adapter, reason, model: data.requested_model)

      :error ->
        :ok
    end
  end

  defp maybe_capture_structured_failure(_data), do: :ok

  @spec reviewer_driver_opts(data(), pid()) :: keyword()
  defp reviewer_driver_opts(data, parent) do
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
  @spec running_idle_timeout(data()) :: timeout()
  defp running_idle_timeout(%{implementer_idle_timeout: idle}) when not is_nil(idle), do: idle

  defp running_idle_timeout(data), do: implementer_idle_timeout(data.idle_timeout)

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
  @spec reviewer_invocation_prompt(data()) :: String.t()
  defp reviewer_invocation_prompt(%{reviewer_reprompt_count: count} = data) when count > 0, do: reviewer_reprompt(data)

  defp reviewer_invocation_prompt(data), do: reviewer_prompt(data)

  # Task 203 re-prompt (generalized): a fresh invocation of the same reviewer
  # whose prior pass left no READABLE verdict — it either exited without writing
  # the artifact or wrote invalid JSON. All review work is already committed in
  # this worktree; the ONE remaining job is producing a valid artifact. Terse by
  # design — the verdict schema + the task framing the agent needs to ground an
  # honest approve/reject, nothing more.
  @spec reviewer_reprompt(data()) :: String.t()
  defp reviewer_reprompt(data) do
    """
    You are the cross-family reviewer for a harness run. You already reviewed this work in a prior
    pass, but harness could not read a valid verdict from `#{Review.artifact_path()}` — it was missing
    or contained invalid JSON, so harness is about to discard the entire run.

    This is your ONLY remaining job, nothing else: all prior fixes are already committed in this
    worktree — assess its current state, run the project's checks below if you need to confirm, then
    write a VALID verdict file NOW and stop. Do not re-do a full review or make new changes unless a
    check is actually failing.

    Verdict artifact — write this, then stop:

    #{Review.artifact_path()}
    {
      "verdict": "approve" | "reject",
      "report": "<what you found, what you fixed, why you decided>",
      "facets": {"language": "...", "surface": "...", "archetype": "...", "difficulty": "...", "risk": "..."},
      "skills": {"<domain or quality the diff exercised>": {"score": <0-10>, "note": "<one line>"}}
    }

    `facets` characterizes what this task ACTUALLY was, read from the spec + the real diff (open
    vocabulary). `skills` scores ONLY the domains and qualities the diff genuinely exercised (otp,
    ecto, concurrency, error_handling, idiom, test_rigor, security, docs, truthfulness, ...) — each a
    {"score": 0-10, "note": "..."} map, open vocabulary, no padding with zeros.

    Fixing is cheaper than rejecting — approve anything salvageable; reject only if nothing is.
    A missing or malformed #{Review.artifact_path()} fails this run for good.

    Project check hint (run these yourself if confirming; judge the output):
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
  @spec reviewer_prompt(data()) :: String.t()
  defp reviewer_prompt(data) do
    """
    You are the cross-family reviewer for a harness run — THE gate that decides whether this work is accepted.

    #{reviewer_situation(data)}

    Your job, in order:
    1. Review the work against the task spec and acceptance criteria below.
    2. Run the project's checks yourself (hint below) and judge the results.
    3. Fix everything that needs fixing — your own edits, your own commits. Wrong approach, bugs,
       missing tests, failing checks, style: fix it all, then approve.
    4. LAST, after every fix and check is done: write your verdict to `#{Review.artifact_path()}`
       (format below). This is your FINAL action — write the file, then stop.

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
  @spec reviewer_situation(data()) :: String.t()
  defp reviewer_situation(%{implementer_empty_diff?: true}) do
    String.trim_trailing("""
    The implementer produced NO diff in this worktree. The transcript tail below shows what it
    did — it may have hit a usage limit, crashed, or believed the work was already done. Decide
    what the empty diff means:
    - Already implemented / you can implement it: do the work or verify it, run the checks, approve.
    - Nothing happened and nothing is salvageable: reject, and say why in your report.
    """)
  end

  defp reviewer_situation(_data) do
    String.trim_trailing("""
    The implementer has committed work in this SAME worktree. It is yours to review, fix, and gate.
    """)
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

    Text.valid_utf8_tail(tail)
  end

  @spec diff_stat(data()) :: String.t()
  defp diff_stat(data) do
    case Git.run(["diff", "--stat", "#{data.worktree.base_sha}..HEAD"], data.worktree.path) do
      {:ok, stat} -> String.trim(stat)
      {:error, reason} -> "diff stat unavailable: #{inspect(reason)}"
    end
  end

  @spec reviewer_commit_message(data()) :: String.t()
  defp reviewer_commit_message(data) do
    "harness: reviewer fixes — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  # ── In-run discernment (sampled live-transcript review) ──────────────────
  #
  # A cross-family grader samples the implementer's partial transcript while it
  # works and can halt a high-confidence rogue/destructive/spinning attempt.
  # The halted attempt routes through the normal pipeline (commit → review);
  # there is no procedural re-dispatch loop.

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
    # and route whatever it left through the normal pipeline — commit, then let
    # the cross-family reviewer judge the worktree. Never a procedural
    # re-dispatch.
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

  @spec truncate_semantic_diff(String.t()) :: String.t()
  defp truncate_semantic_diff(diff) when byte_size(diff) <= @semantic_diff_max_bytes, do: diff

  defp truncate_semantic_diff(diff) do
    head = binary_part(diff, 0, @semantic_diff_max_bytes)

    "[harness: showing the first #{@semantic_diff_max_bytes} of #{byte_size(diff)} bytes]\n" <>
      Text.valid_utf8_head(head)
  end

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
  @spec task_d_score(data()) :: non_neg_integer()
  defp task_d_score(%{item: %Item{d: d}}) when is_integer(d), do: d
  defp task_d_score(_data), do: 0

  # The typed `:security` / `:bug` markers from rmap, not a prose keyword scrape:
  # catches a :security-tagged task whose prose never says "security", and does
  # not false-positive on a body that merely mentions "fixed a bug".
  @spec high_stakes_marker?(data()) :: boolean()
  defp high_stakes_marker?(%{item: %Item{markers: markers}}), do: :security in markers or :bug in markers

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
  # An explicit :base_ref (e.g. a resumed run branching off the retained
  # harness/<old-run-id> branch) wins over the computed origin/<target> base.
  defp worktree_opts(%{base_ref: base_ref} = data) when is_binary(base_ref) and base_ref != "" do
    Keyword.put(base_worktree_opts(data), :base_ref, base_ref)
  end

  defp worktree_opts(%{project: %Project{target_branch: target}} = data) when is_binary(target) and target != "" do
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

  defp worktree_opts(data) do
    base_worktree_opts(data)
  end

  @spec base_worktree_opts(data()) :: keyword()
  defp base_worktree_opts(data) do
    put_opt([id: data.run_id, substrate_retry: data.substrate_retry], :base_dir, data.base_dir)
  end

  @spec fetch_target(Project.t(), String.t(), keyword()) :: :ok | {:error, Git.error()}
  defp fetch_target(%Project{} = project, target, substrate_retry) do
    case retry_substrate(substrate_retry, fn -> Git.run(["fetch", "origin", target], Project.repo_path(project)) end) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_driver(data(), module(), Invocation.t(), keyword()) :: {:ok, Outcome.t()} | {:error, term()}
  defp run_driver(data, adapter, %Invocation{} = invocation, opts) do
    retry_substrate(data.substrate_retry, fn -> Driver.run(adapter, invocation, opts) end)
  end

  @spec retry_substrate(keyword(), (-> term())) :: term()
  defp retry_substrate(opts, fun) when is_function(fun, 0) do
    policy = RetryPolicy.new(opts)
    do_retry_substrate(fun, policy, 1)
  end

  @spec do_retry_substrate((-> term()), RetryPolicy.t(), pos_integer()) :: term()
  defp do_retry_substrate(fun, %RetryPolicy{} = policy, attempt) do
    case fun.() do
      {:error, _reason} = error when attempt > policy.max_retries ->
        error

      {:error, _reason} ->
        Process.sleep(RetryPolicy.backoff_ms(policy, attempt))
        do_retry_substrate(fun, policy, attempt + 1)

      other ->
        other
    end
  end

  @spec driver_opts(data(), pid()) :: keyword()
  defp driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:run_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, implementer_idle_timeout(data.idle_timeout))
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  @spec commit_worktree(data(), Worktree.t(), String.t()) ::
          {:ok, :committed | :no_changes, non_neg_integer()} | {:error, Worktree.error()}
  defp commit_worktree(data, %Worktree{} = worktree, message) do
    retry_substrate(data.substrate_retry, fn ->
      with {:ok, diff_size} <- Worktree.diff_size(worktree),
           {:ok, status} <- Worktree.commit(worktree, message, substrate_retry: [max_retries: 0]) do
        {:ok, status, diff_size}
      end
    end)
  end

  @spec put_opt(keyword(), atom(), term()) :: keyword()
  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec normalize_opts(nil | keyword() | map()) :: keyword()
  defp normalize_opts(nil), do: []
  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)

  @spec checkout_snapshot_for_run(data()) :: String.t() | nil
  defp checkout_snapshot_for_run(%{checkout_pollution_check?: true} = data) do
    checkout_snapshot(Project.repo_path(data.project))
  end

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

  # Resolves a run timeout: explicit opt wins, else the `Harness.Config` schema
  # value (schema default folded with any persisted operator override). Keeps the
  # `||` fallbacks out of `init/1` so it stays under the complexity gate, and
  # routes the read through the schema (Task 167) — defaults live in `Config`, not
  # in `@default_*` attributes here.
  @spec run_timeout(keyword(), atom()) :: timeout() | nil
  defp run_timeout(opts, key) do
    Keyword.get(opts, key) || Config.get({:run, key})
  end

  # Resolves the per-run memory watchdog ceiling + sample interval (Task 200):
  # explicit opt > app env > module default. Kept out of `init/1`'s data map so
  # the `||` fallbacks don't push init over the cyclomatic-complexity gate.
  @spec mem_watchdog_config(keyword()) :: {pos_integer(), pos_integer()}
  defp mem_watchdog_config(opts) do
    {Keyword.get(opts, :mem_threshold_kb) || configured(:mem_threshold_kb, @default_mem_threshold_kb),
     Keyword.get(opts, :mem_sample_interval) || configured(:mem_sample_interval, @default_mem_sample_interval)}
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
