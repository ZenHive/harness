defmodule Harness.Dispatch do
  @moduledoc """
  Flat, JSON-native dispatch surface for the chat/MCP orchestrator.

  The canonical Elixir driver path is the two-step
  `Harness.Roadmap.ingest/2` → `Harness.Run.Supervisor.start_run/4`, where the
  ingested `%Harness.Roadmap.Item{}` struct is threaded into `start_run`. That
  shape cannot be driven over a stateless JSON boundary: an MCP/chat caller has
  no way to hold the `%Item{}` between two tool calls, and `start_run` takes
  `%Item{}` / `%Project{}` structs a JSON caller cannot construct.

  `task/4` collapses the whole flow into one tool that takes only
  JSON-passable scalars — a registered project name, a task selector
  (id string or `"next"`), an adapter name, and a secret-scrub boolean — and
  returns a `run_id`. Internally it resolves the project, ingests the task,
  applies the Claude OAuth secret scrub by default, and starts the supervised
  run with no subscriber (the eval/MCP process is ephemeral; observe the run
  later via its `run_id`).

  `await/5` is the blocking variant: same dispatch, but it subscribes the
  calling process to the run and blocks until the run settles, returning a
  compact verdict summary as the tool result instead of a `run_id` the
  orchestrator must then poll. The wait is bounded by `timeout_ms`; if the
  budget elapses first, it returns a structured `:timed_out` summary (carrying
  the `run_id` so the run — which keeps going — can still be observed later)
  rather than wedging the tool call. `task/4` (fire-and-forget) is unchanged
  alongside it.

  `resume_failed/2` and `rereview/1` are distinct salvage primitives. Use
  `resume_failed/2` when the implementer failed and should continue from the
  retained `harness/<run-id>` branch. Use `rereview/1` when the implementation
  is already committed and only the review stage failed; it branches a fresh
  worktree from the retained branch and enters the reviewer gate directly.

  ## Adapter vocabulary

  `rmap delegate --to` renders a native prompt for every harness adapter —
  `claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi` — so each is a valid
  `adapter` here and is dispatched directly (no claude-rendered two-step). rmap
  can also render `droid`, but harness has no Droid adapter, so `droid` resolves
  to `{:unknown_adapter, "droid"}`. Adding a new executor is two-sided: an rmap
  `delegate --to` target (the rmap binary is ours, `../rmap/`) plus a harness
  `Harness.AgentAdapter` — the render side already exists for `droid`.
  """

  # Manifest derives MCP names from this module; keep declarations and defaults
  # here while the concern modules own execution and presentation.
  use Descripex, namespace: "/dispatch"

  import Harness.Dispatch.Presentation, only: [summarize_transcript: 1, summarize_transcript_events: 1]
  import Harness.Dispatch.RunTool

  alias Harness.Batch
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.DependencyBump
  alias Harness.Dispatch.Admin
  alias Harness.Dispatch.Bundles
  alias Harness.Dispatch.Compare
  alias Harness.Dispatch.Lifecycle
  alias Harness.Dispatch.Observation
  alias Harness.Dispatch.Presentation
  alias Harness.Dispatch.Resolution
  alias Harness.Dispatch.RunSummary
  alias Harness.Dispatch.Submission
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.ToolingBaseline.Dispatch, as: ToolingBaselineDispatch
  alias Oban.Job

  @default_await_timeout_ms 1_800_000
  @recommended_adapter "recommend"

  @typedoc "A reason a dispatch tool can fail with (in addition to the ingest/start_run reasons it forwards)."
  @type error ::
          {:unknown_adapter, String.t()}
          | {:non_delegatable_adapter, String.t()}
          | {:unknown_project, String.t()}
          | {:unavailable, atom(), String.t() | nil, keyword()}
          | :no_adapters
          | Roadmap.error()
          | Batch.error()
          | term()

  api(
    :task,
    "Dispatch one roadmap task for a registered project end-to-end: ingest it and start a supervised, reviewer-gated run on the chosen adapter. Returns a run_id. The single JSON-native dispatch entry point for chat/MCP orchestrators.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry-list."
      ],
      task: [
        kind: :value,
        description:
          ~s{Task selector: a task id string (e.g. "25"), or "next" for the next pending task by rmap's D/B/U scoring.}
      ],
      adapter: [
        kind: :value,
        default: @recommended_adapter,
        description:
          "Executor: recommend | claude | codex | cursor | grok | antigravity | pi. recommend matches the task's facets against the scout's per-facet assessment and falls back safely when no data exists; explicit adapter names bypass recommendation."
      ],
      scrub_anthropic_key: [
        kind: :value,
        default: true,
        description:
          "When true (default), scrubs ANTHROPIC_API_KEY from the agent's environment so Claude dispatches use subscription OAuth instead of the metered API. Harmless for non-Claude adapters."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id: run_id}} on a started run. {:error, reason}: unknown_adapter, unknown_project, the rmap ingest reasons, or a start_run failure (e.g. worktree isolation rejection for antigravity)."
    }
  )

  @spec task(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, %{run_id: String.t()}} | {:error, error()}
  def task(project_name, task, adapter \\ @recommended_adapter, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(task) and is_binary(adapter) and is_boolean(scrub_anthropic_key),
      do: Submission.task(project_name, task, adapter, scrub_anthropic_key)

  api(
    :await,
    "Dispatch one roadmap task and block until the run settles, returning a compact summary (state, reason, the reviewer AI's verdict) instead of a run_id to poll. The bounded blocking variant of dispatch-task — one call gets the answer. Goes through the same Oban-guarded path as dispatch-task: an await for a task already in flight ATTACHES to the existing run (no duplicate dispatch) and awaits it. The wait is capped by timeout_ms; on timeout it returns a structured :timed_out summary (the run keeps going, observable later via run_id), never a wedged tool call.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry-list."
      ],
      task: [
        kind: :value,
        description:
          ~s{Task selector: a task id string (e.g. "25"), or "next" for the next pending task by rmap's D/B/U scoring.}
      ],
      adapter: [
        kind: :value,
        default: @recommended_adapter,
        description:
          "Executor: recommend | claude | codex | cursor | grok | antigravity | pi. recommend matches the task's facets against the scout's per-facet assessment and falls back safely when no data exists; explicit adapter names bypass recommendation."
      ],
      timeout_ms: [
        kind: :value,
        default: @default_await_timeout_ms,
        description:
          "Maximum milliseconds to block for the run to settle (default 1_800_000 = 30 min). On expiry the tool returns a structured :timed_out summary; the run is NOT cancelled and stays observable via its run_id."
      ],
      scrub_anthropic_key: [
        kind: :value,
        default: true,
        description:
          "When true (default), scrubs ANTHROPIC_API_KEY from the agent's environment so Claude dispatches use subscription OAuth instead of the metered API. Harmless for non-Claude adapters."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, summary} where summary is a settled-run map (run_id, task_id, state :done|:failed, reason, passed, review with the reviewer's verdict/report/ratings, agent_diff_size, reviewer_diff_size) OR a :timed_out map (run_id, state :timed_out, reason :await_timeout, timeout_ms). {:error, reason} on a dispatch failure (unknown_adapter, unknown_project, the rmap ingest reasons, or a start_run failure) — same as dispatch-task."
    }
  )

  @spec await(String.t(), String.t(), String.t(), number(), boolean()) ::
          {:ok, map()} | {:error, error()}
  def await(
        project_name,
        task,
        adapter \\ @recommended_adapter,
        timeout_ms \\ @default_await_timeout_ms,
        scrub_anthropic_key \\ true
      )
      when is_number(timeout_ms) and timeout_ms > 0 and is_boolean(scrub_anthropic_key) and is_binary(project_name) and
             is_binary(task) and is_binary(adapter),
      do: Observation.await(project_name, task, adapter, timeout_ms, scrub_anthropic_key)

  @doc false
  @spec await_result(String.t(), number()) :: {:ok, map()}
  def await_result(run_id, timeout_ms) when is_binary(run_id) and is_number(timeout_ms) and timeout_ms > 0,
    do: Observation.await_result(run_id, timeout_ms)

  api(
    :update_deps,
    "Operator-triggered dependency update: create dependency-bump roadmap task(s) from the latest dep-freshness facts and dispatch them through the normal implementer -> reviewer -> land agent gate. Harness does NOT run dependency update commands or tests itself.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry-list."
      ],
      adapter: [
        kind: :value,
        default: "codex",
        description:
          "Executor for the generated bump task(s): codex | cursor | grok | antigravity | pi | claude. The generated rmap task is also assigned to this adapter unless adapter is recommend."
      ],
      model: [
        kind: :value,
        default: nil,
        description:
          "Optional model id to pin on the generated bump task(s), e.g. gpt-6-astra for codex; must be in the agent's live catalog (model_availability-list_available_models). nil leaves the per-agent configured model in control."
      ],
      scrub_anthropic_key: [
        kind: :value,
        default: true,
        description:
          "When true (default), scrubs ANTHROPIC_API_KEY from the agent's environment. Harmless for non-Claude adapters."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{project_name, tasks: [%{task_id, run_id, language, kind, dependencies, check_command}]}}. The tasks are generated from stored dep-freshness facts and enqueued through Harness.Run.Worker; harness performs no dep update or verification itself. {:error, reason}: unknown project/adapter, missing freshness snapshot, rmap failure, or enqueue failure."
    }
  )

  @spec update_deps(String.t(), String.t(), String.t() | nil, boolean()) ::
          {:ok, DependencyBump.result()} | {:error, DependencyBump.error()}
  def update_deps(project_name, adapter \\ "codex", model \\ nil, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(adapter) and (is_binary(model) or is_nil(model)) and
             is_boolean(scrub_anthropic_key) do
    DependencyBump.dispatch(project_name, adapter, model, scrub_anthropic_key)
  end

  api(
    :tooling_baseline,
    "Operator-triggered tooling-baseline install: create a task from stored conformance-drift facts and dispatch it through the normal implementer -> reviewer -> land agent gate. Harness does NOT edit mix.exs, install deps, build, or verify the project itself.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry-list."
      ],
      adapter: [
        kind: :value,
        default: "codex",
        description:
          "Executor for the generated tooling-baseline task: codex | cursor | grok | antigravity | pi | claude. The generated rmap task is also assigned to this adapter unless adapter is recommend."
      ],
      model: [
        kind: :value,
        default: nil,
        description:
          "Optional model id to pin on the generated tooling-baseline task, e.g. gpt-6-astra for codex; must be in the agent's live catalog (model_availability-list_available_models). nil leaves the per-agent configured model in control."
      ],
      scrub_anthropic_key: [
        kind: :value,
        default: true,
        description:
          "When true (default), scrubs ANTHROPIC_API_KEY from the agent's environment. Harmless for non-Claude adapters."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{project_name, tasks: [%{task_id, run_id, language, kind, missing, skipped_languages, check_command}], skipped_languages}}. The task is generated from stored tooling-baseline conformance facts and enqueued through Harness.Run.Worker; harness performs no install or verification itself. {:error, reason}: unknown project/adapter, missing conformance snapshot, rmap failure, or enqueue failure."
    }
  )

  @spec tooling_baseline(String.t(), String.t(), String.t() | nil, boolean()) ::
          {:ok, ToolingBaselineDispatch.result()} | {:error, ToolingBaselineDispatch.error()}
  def tooling_baseline(project_name, adapter \\ "codex", model \\ nil, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(adapter) and (is_binary(model) or is_nil(model)) and
             is_boolean(scrub_anthropic_key) do
    ToolingBaselineDispatch.dispatch(project_name, adapter, model, scrub_anthropic_key)
  end

  api(
    :await_runs,
    "Block until an arbitrary set of already-started runs settles, returning compact per-run summaries. The wait is capped by timeout_ms; on expiry settled runs are returned as settled and unfinished runs are returned as :timed_out markers. Runs keep going and stay observable later via dispatch-status.",
    params: [
      run_ids: [
        kind: :value,
        description:
          "List of run id strings returned by dispatch-task, dispatch-bundle, dispatch-await, or supervisor-list_runs."
      ],
      timeout_ms: [
        kind: :value,
        default: @default_await_timeout_ms,
        description:
          "Maximum milliseconds to block for all runs to settle (default 1_800_000 = 30 min). On expiry, unfinished runs return structured :timed_out summaries; they are NOT cancelled."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, [%{run_id, state, reason, review_verdict}]} where terminal runs keep their :done/:failed state, unknown ids report :not_found, and unfinished runs report state :timed_out with reason :await_timeout when the timeout expires."
    }
  )

  @spec await_runs([String.t()], number()) :: {:ok, [map()]}
  def await_runs(run_ids, timeout_ms \\ @default_await_timeout_ms)
      when is_list(run_ids) and is_number(timeout_ms) and timeout_ms > 0 do
    Observation.await_runs(run_ids, timeout_ms)
  end

  api(
    :status,
    "Snapshot one run by run_id at any lifecycle stage: live (in-flight/lingering), queued (unfinished Oban job), or SETTLED (rehydrated from the persisted record). State + the reviewer's verdict so far. Returns {:error, :not_found} only for a run_id with no live process, no queued job, AND no persisted record — i.e. genuinely unknown, not merely finished.",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id string returned by dispatch-task / dispatch-await (or supervisor-list_runs). A stopped/unknown run yields {:error, :not_found}."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, map} carrying run_id, task_id, project_name, state, worktree_path, agent_os_pid, agent_kind, review_verdict, reason. A settled run rehydrated from its record reports its terminal state (:done/:failed) with worktree_path/agent_os_pid nil. {:error, :not_found} only for a genuinely unknown run_id."
    }
  )

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(run_id), do: Observation.status(run_id)

  defrun_tool(
    name: :transcript,
    summarize: :summarize_transcript,
    description:
      "Return the buffered raw agent transcript and last seq tag for an in-flight or lingering run, by run_id. Poll with the prior seq to detect new output. For a settled run's full record use result_store-list_run_records.",
    run_id_doc:
      "Run id string returned by dispatch-task / dispatch-await. A stopped/unknown run yields {:error, :not_found}.",
    returns:
      "{:ok, %{transcript: binary (bounded ~200 KiB), seq: non_neg_integer}}. {:error, :not_found} for stopped/unknown runs."
  )

  defrun_tool(
    name: :transcript_events,
    summarize: :summarize_transcript_events,
    description:
      "Return the parsed transcript events (assistant text, tool calls, tool results, system events) + last seq tag for an in-flight or lingering run, by run_id. Events are flattened to JSON-safe maps tagged with a :type.",
    run_id_doc:
      "Run id string returned by dispatch-task / dispatch-await. A stopped/unknown run yields {:error, :not_found}.",
    returns:
      "{:ok, %{events: [%{type: atom, ...}], agent_kind: atom | nil, seq: non_neg_integer}}. {:error, :not_found} for stopped/unknown runs."
  )

  api(
    :cancel,
    "Cancel an in-flight run by run_id: kills the agent and settles the run :failed. Idempotent — cancelling a settled or unknown run is a no-op. The JSON-native counterpart to Harness.Run.cancel/1.",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id string returned by dispatch-task / dispatch-await. Cancelling a stopped/unknown run is a harmless no-op."
      ]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, %{run_id: run_id, cancelled: true}} — always; cancellation is idempotent."
    }
  )

  @spec cancel(String.t()) :: {:ok, %{run_id: String.t(), cancelled: true}}
  def cancel(run_id), do: Lifecycle.cancel(run_id)

  api(
    :hold,
    "Park an in-flight run in :held for operator-mediated recovery, by run_id. Graceful (default) waits for the current agent attempt to finish; interrupt: true kills the agent immediately. The JSON-native counterpart to Harness.Run.hold/2 — a mechanical lifecycle transition, not a judgment.",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id string returned by dispatch-task / dispatch-await (or supervisor-list_runs). A stopped/unknown run yields {:error, :not_found}."
      ],
      interrupt: [
        kind: :value,
        default: false,
        schema: boolean(),
        description:
          "When true, terminate the agent now and park immediately; when false, park at the next attempt boundary."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id, held: true, interrupt: bool}} on a parked run. {:error, reason}: :terminal (already settled), :invalid_state, or :not_found."
    }
  )

  @spec hold(String.t(), boolean()) ::
          {:ok, %{run_id: String.t(), held: true, interrupt: boolean()}}
          | {:error, :terminal | :invalid_state | :not_found}

  def hold(run_id, interrupt \\ false), do: Lifecycle.hold(run_id, interrupt)

  api(
    :steer,
    "Stash operator guidance for the next agent boundary of a run (append-accumulates), by run_id. Requires a session-resume-capable adapter. The JSON-native counterpart to Harness.Run.steer/2 — it records a note for the next resumed attempt; it does not itself judge or act on the run.",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id string returned by dispatch-task / dispatch-await. A stopped/unknown run yields {:error, :not_found}."
      ],
      text: [
        kind: :value,
        description: "Operator note threaded into the next resumed agent attempt."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id, steered: true}} when the note is stashed. {:error, reason}: :resume_unsupported (adapter cannot resume) or :not_found."
    }
  )

  @spec steer(String.t(), String.t()) ::
          {:ok, %{run_id: String.t(), steered: true}}
          | {:error, :resume_unsupported | :not_found}

  def steer(run_id, text), do: Lifecycle.steer(run_id, text)

  api(
    :resume,
    "Resume a :held run, by run_id — re-enters :running with a session-resume invocation in the same worktree (any stashed steer note is applied). A question-held run requires a prior dispatch-steer answer (`:answer_required` otherwise). The JSON-native counterpart to Harness.Run.resume/1 — a mechanical lifecycle transition.",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id string of a currently :held run (see dispatch-status). A non-held or unknown run yields an error."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id, resumed: true}} on re-entry to :running. {:error, reason}: :not_held (run was not parked), :answer_required (question-held run has no steer answer yet), or :not_found."
    }
  )

  @spec resume(String.t()) ::
          {:ok, %{run_id: String.t(), resumed: true}} | {:error, :not_held | :answer_required | :not_found}
  def resume(run_id), do: Lifecycle.resume(run_id)

  api(
    :resume_failed,
    "Resume a SETTLED :failed run by run_id: re-dispatch its roadmap task on a NEW run that branches off the retained harness/<run-id> branch (the prior attempt's commits are the starting point) with the failure report injected into the prompt — the implementer continues from prior work instead of redoing it. Same agent by default; escalate=true routes via the per-facet scout assessment to the recommended agent for the task's predicted facets. DISTINCT from dispatch-resume, which un-pauses a live :held run.",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id of a settled :failed run (from dispatch-status / result_store-list_run_records). {:error, :not_found} when unrecorded, {:error, :not_failed} when the run did not fail."
      ],
      escalate: [
        kind: :value,
        default: false,
        description:
          "When true, pick the agent via the scout's per-facet assessment on the task's predicted facets (reuses the dispatch-task recommend path). When false (default), reuse the agent that ran originally."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id: new_run_id, resumed_from: old_run_id, agent: atom}} on an enqueued run. {:error, reason}: :not_found, :not_failed, the ingest reasons, or a start_run failure."
    }
  )

  @spec resume_failed(String.t(), boolean()) ::
          {:ok, %{run_id: String.t(), resumed_from: String.t(), agent: atom() | nil}}
          | {:error, error()}

  def resume_failed(run_id, escalate \\ false), do: Lifecycle.resume_failed(run_id, escalate)

  api(
    :rereview,
    "Re-review a SETTLED run by run_id without re-running the implementer: branch a new worktree off retained harness/<run-id> and enter Harness.Run directly at the reviewer gate. Use this for review-stage failures where the committed work is already good; use dispatch-resume_failed for implement-stage failures where the implementer must continue the work.",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id with a persisted record and retained harness/<run-id> branch. {:error, :not_found} when unrecorded, {:error, :unknown_project} when its project is no longer registered."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id: new_run_id, rereviewed_from: old_run_id, agent: atom}} on an enqueued review-only run. {:error, reason}: :not_found, :unknown_project, the ingest reasons, or a start_run failure."
    }
  )

  @spec rereview(String.t()) ::
          {:ok, %{run_id: String.t(), rereviewed_from: String.t(), agent: atom() | nil}}
          | {:error, error()}

  def rereview(run_id), do: Lifecycle.rereview(run_id)

  @doc false
  @spec resume_adapter(LogRecord.t(), boolean()) :: String.t()
  def resume_adapter(record, escalate), do: Lifecycle.resume_adapter(record, escalate)

  @doc false
  @spec resume_item(Item.t(), LogRecord.t()) :: Item.t()
  def resume_item(item, record), do: Lifecycle.resume_item(item, record)

  @doc false
  @spec resume_opts(Item.t(), String.t()) :: keyword()
  def resume_opts(item, old_run_id), do: Lifecycle.resume_opts(item, old_run_id)

  @doc false
  @spec rereview_opts(Item.t(), LogRecord.t(), String.t()) :: keyword()
  def rereview_opts(item, record, old_run_id), do: Lifecycle.rereview_opts(item, record, old_run_id)

  api(
    :reland,
    "Re-enqueue a landing job for a run by run_id whose automatic land-train hit its cap and blocked the task: re-fetch, rebase the retained harness/<run-id> branch onto the current target, and push. ZERO agent tokens — pure git, the branch is already built and reviewer-approved. The JSON-native counterpart to Harness.Lander.enqueue/1; mechanical (the caller decides a re-land is warranted, harness only re-enqueues).",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id of a settled run with a retained harness/<run-id> branch (typically a run whose task is blocked by a land-cap). {:error, :not_found} when no persisted record exists, {:error, :unknown_project} when its project is no longer registered."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id, task_id}} on enqueue. {:error, reason}: :not_found, :unknown_project, or an Oban insert failure."
    }
  )

  @spec reland(String.t()) ::
          {:ok, %{run_id: String.t(), task_id: String.t()}} | {:error, error()}
  def reland(run_id), do: Lifecycle.reland(run_id)

  api(
    :pending,
    "List autonomous (cron) dispatch decisions parked for operator approval because their project's cron dispatch mode is :manual. Each entry carries the pending id (pass to dispatch-approve), project, task, the resolved adapter, and when it was parked. Interactive dispatch-task / dispatch-await are never parked — only the cron path is.",
    params: [
      project_name: [
        kind: :value,
        default: nil,
        description:
          "Optional registered project name to filter parked decisions; omit/null lists every project's pending decisions."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{pending: [%{id, project_name, task_id, adapter, parked_at}]}} — possibly empty. parked_at is ISO8601."
    }
  )

  @spec pending(String.t() | nil) :: {:ok, %{pending: [map()]}}
  def pending(project_name \\ nil), do: Admin.pending(project_name)

  api(
    :approve,
    "Approve a parked autonomous-dispatch decision by its pending id (from dispatch-pending), draining it into the normal reviewer-gated run loop on the adapter the orchestrator already resolved. Idempotent: a second approval of the same id, or an unknown id, returns {:error, :not_found} (the guard that makes double-enqueue impossible). The operator approval gate for :manual cron dispatch mode.",
    params: [
      pending_id: [
        kind: :value,
        description:
          ~s|Pending decision id from dispatch-pending (e.g. "myapp:42"). An unknown/already-approved id returns {:error, :not_found}.|
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id, task_id, project_name, adapter}} on a started run. {:error, reason}: :not_found, {:unknown_project, name}, the rmap ingest reasons, or an Oban insert failure."
    }
  )

  @spec approve(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def approve(pending_id) when is_binary(pending_id), do: approve(pending_id, nil)

  @doc "Approves the exact parked generation displayed to an operator."
  @spec approve(String.t(), DateTime.t() | nil) :: {:ok, map()} | {:error, term()}
  def approve(pending_id, parked_at) when is_binary(pending_id), do: Admin.approve(pending_id, parked_at)

  # --- Project registration over JSON ---
  #
  # Harness.ProjectRegistry.register/1 takes a %Harness.Project{} struct
  # (:exchange_data — off the JSON surface). This is the flat scalar entry point:
  # it assembles the struct through the registry's validated builder so a runtime
  # registration behaves identically to a config :harness, :projects entry. The
  # rarer struct fields (landing_policy, target_branch, pollution_allowlist) are
  # intentionally NOT exposed here — register those via config or the project_eval
  # struct path (see docs/orchestrator-surface-inventory.md § Omissions).
  # `roadmap_target_branch` IS exposed: split-repo registrations cannot set it
  # any other JSON-native way, and omitting it keeps the same-repo derivation
  # from `target_branch`.

  api(
    :register_project,
    "Register a project for dispatch from JSON scalars: build a validated %Harness.Project{} (with path expansion, same as a config entry) and register it. The JSON-native counterpart to Harness.ProjectRegistry.register/1. Registration persists to Postgres by default (:repo_enabled defaults to true) and survives a BEAM restart. Set repo_enabled: false for ephemeral in-memory registration. config :harness, :projects only seeds missing rows on first boot.",
    params: [
      name: [
        kind: :value,
        description:
          ~s|Project name slug (e.g. "myapp"). Must be unique; a taken slug returns {:error, {:duplicate, name}}.|
      ],
      source_type: [
        kind: :value,
        description: ~s{Project source kind: "local" (a filesystem path) or "github" (a clone URL).}
      ],
      source_location: [
        kind: :value,
        description: "Filesystem path (for local) or clone URL (for github) of the project source."
      ],
      roadmap_path: [
        kind: :value,
        description: "Filesystem path to the project root containing roadmap/tasks.toml (resolves rmap browse/ingest)."
      ],
      languages: [
        kind: :value,
        description:
          "Required non-empty list of target-language atoms for provider selection and injected agent rules. :mixed is not accepted.",
        # Pin independently of @spec conversion so a nonempty_list/union spec
        # cannot ship a typeless property that MCP clients stringify (bugs.md #3).
        schema: [String.t()]
      ],
      check_command: [
        kind: :value,
        default: nil,
        description:
          ~s{Optional free-text dispatch-scale hint handed to the reviewer AI (e.g. "mix check.dispatch"). Harness never runs it; the reviewer runs the project's checks itself.}
      ],
      concurrency_cap: [
        kind: :value,
        default: nil,
        description: "Optional per-project max concurrent runs (the project's Oban queue limit). nil leaves the default."
      ],
      warm_paths: [
        kind: :value,
        default: [],
        description:
          "Optional repo-relative gitignored directories to seed into fresh worktrees in addition to the default warm paths."
      ],
      roadmap_target_branch: [
        kind: :value,
        default: nil,
        description:
          "Optional git branch for durable roadmap commits. Required when roadmap_path and source are different repositories. Omit/blank for same-repo registrations, which derive the durable branch from target_branch. Invalid names return {:error, {:invalid_project, {:invalid_roadmap_target_branch, value}}}."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{name: name}} on success. {:error, reason}: {:invalid_source_type, value}, {:invalid_project, {:invalid_roadmap_target_branch, _}} (or other missing/invalid field), or {:duplicate, name}."
    }
  )

  @spec register_project(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          nonempty_list(atom() | String.t()),
          String.t() | nil,
          pos_integer() | nil,
          [String.t()],
          String.t() | nil
        ) ::
          {:ok, %{name: String.t()}} | {:error, term()}

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def register_project(
        name,
        source_type,
        source_location,
        roadmap_path,
        languages,
        check_command \\ nil,
        concurrency_cap \\ nil,
        warm_paths \\ [],
        roadmap_target_branch \\ nil
      )
      when is_binary(name) and is_binary(source_type) and is_binary(source_location) and is_binary(roadmap_path),
      do:
        Admin.register_project(
          name,
          source_type,
          source_location,
          roadmap_path,
          languages,
          check_command,
          concurrency_cap,
          warm_paths,
          roadmap_target_branch
        )

  api(
    :bundle,
    "Dispatch the first collision-free wave from the next session-sized bundle of pending roadmap tasks for a registered project: tasks whose `touches`/`files_to_modify` overlap are serialized into later waves instead of enqueued together. Fire-and-forget for the dispatched wave — returns the dispatched task ids, Oban job ids, and the serialized wave plan; observe each run later via dispatch-status / result_store-list_run_records. The JSON-native counterpart to Harness.Roadmap.next_bundle/1 + Harness.Batch.dispatch/2.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry-list."
      ],
      adapter: [
        kind: :value,
        default: "claude",
        description:
          "Executor: claude | codex | cursor | grok | antigravity | pi. The Oban bundle path keys each job's adapter off the task's render agent; rmap renders natively for all six, so each is accepted. (droid is renderable by rmap but has no harness adapter, so it is rejected as unknown_adapter.)"
      ],
      scrub_anthropic_key: [
        kind: :value,
        default: true,
        description:
          "When true (default), scrubs ANTHROPIC_API_KEY from each enqueued run's environment so Claude bundle dispatches use subscription OAuth instead of the metered API. Threaded through the Oban job args into the worker's start_run :env, matching dispatch-task / dispatch-await / dispatch-compare. Harmless for non-Claude adapters."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{bundle: bundle_meta | nil, task_ids: [string], job_ids: [integer], dispatched: integer, serialized: %{waves: [[string]], collisions: [%{task_ids, shared_files}]}}}. task_ids are only the tasks enqueued in this call. {:error, reason}: unknown_adapter, non_delegatable_adapter, unknown_project, the rmap next_bundle reasons, or a Harness.Batch.dispatch failure."
    }
  )

  @spec bundle(String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, error()}
  def bundle(project_name, adapter \\ "claude", scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(adapter) and is_boolean(scrub_anthropic_key),
      do: Bundles.bundle(project_name, adapter, scrub_anthropic_key)

  api(
    :coalesce,
    "Dispatch an explicit list of small, related roadmap tasks as one implementer run, one reviewer gate, and one landing unit. Use this only when the tasks share a bundle or surface; use dispatch-bundle to parallelize independent tasks.",
    params: [
      project_name: [kind: :value, description: "Registered project name."],
      task_ids: [kind: :value, description: ~s|At least two explicit roadmap task ids, e.g. ["368", "369"].|],
      adapter: [
        kind: :value,
        default: @recommended_adapter,
        description: "Executor: recommend | claude | codex | cursor | grok | antigravity | pi."
      ],
      scrub_anthropic_key: [kind: :value, default: true, description: "Scrub ANTHROPIC_API_KEY from the run environment."]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id, task_ids, write_set}} for one coalesced run — write_set is the union of every member's `touches`/`files_to_modify`, i.e. the footprint the caller must serialize the next wave against. {:error, reason}: invalid_task_ids (fewer than two distinct ids), unknown_adapter, non_delegatable_adapter, unknown_project, or an rmap ingest reason."
    }
  )

  @spec coalesce(String.t(), [String.t()], String.t(), boolean()) ::
          {:ok, map()} | {:error, error() | :invalid_task_ids}
  def coalesce(project_name, task_ids, adapter \\ @recommended_adapter, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_list(task_ids) and is_binary(adapter) and is_boolean(scrub_anthropic_key),
      do: Bundles.coalesce(project_name, task_ids, adapter, scrub_anthropic_key)

  api(
    :compare,
    "Same-task A/B agent evaluation over JSON: ingest one roadmap task once — rendered once (for claude) so every adapter runs an identical prompt, which is what makes the comparison fair — and run it concurrently across N adapters in isolated worktrees, returning side-by-side per-adapter metrics. Supports all six executors (claude | codex | cursor | grok | antigravity | pi), each running that shared prompt directly. In-process and blocking: returns once every adapter's run has settled. The JSON-native counterpart to Harness.Batch.AgentEvaluation.compare/4.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry-list."
      ],
      task: [
        kind: :value,
        description:
          ~s{Task selector: a task id string (e.g. "25"), or "next" for the next pending task by rmap's D/B/U scoring.}
      ],
      adapters: [
        kind: :value,
        description:
          ~s{Non-empty list of executor names to compare head-to-head, e.g. ["claude", "codex"]. Each runs the same task in its own isolated worktree. claude | codex | cursor | grok | antigravity | pi.}
      ],
      models: [
        kind: :value,
        default: %{},
        description:
          ~s|Optional object mapping adapter name to model id, e.g. {"grok": "grok-4.6", "cursor": "cursor-grok-4.6-high"}. When an adapter is omitted, compare uses that adapter's configured default model, never the task's pinned model.|
      ],
      scrub_anthropic_key: [
        kind: :value,
        default: true,
        description:
          "When true (default), scrubs ANTHROPIC_API_KEY from every adapter's environment so Claude runs use subscription OAuth instead of the metered API. Harmless for non-Claude adapters."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{batch_id, task_id, total, max_concurrency, entries}} where entries is a list of per-adapter maps (adapter, run_id, state, reason, verdict :approve|:reject|nil, reviewer_diff_size, duration_ms, agent_diff_size, token_usage). {:error, reason}: no_adapters, unknown_adapter, unknown_project, invalid/model-required per-adapter models, the rmap ingest reasons, or a Harness.Batch failure."
    }
  )

  @spec compare(String.t(), String.t(), [String.t()]) :: {:ok, map()} | {:error, error()}

  @spec compare(String.t(), String.t(), [String.t()], boolean() | map()) :: {:ok, map()} | {:error, error()}

  @spec compare(String.t(), String.t(), [String.t()], map(), boolean()) :: {:ok, map()} | {:error, error()}
  def compare(project_name, task, adapters, models, scrub_anthropic_key)
      when is_binary(project_name) and is_binary(task) and is_list(adapters) and is_map(models) and
             is_boolean(scrub_anthropic_key),
      do: Compare.compare(project_name, task, adapters, models, scrub_anthropic_key)

  @doc false
  def compare(project_name, task, adapters), do: Compare.compare(project_name, task, adapters)

  @doc false
  def compare(project_name, task, adapters, scrub_anthropic_key),
    do: Compare.compare(project_name, task, adapters, scrub_anthropic_key)

  api(
    :verdict_detail,
    "Read the reviewer AI's verdict detail for a SETTLED run by run_id: the approve/reject decision, the reviewer's prose report (what it found, fixed, and why it decided), and its implementer KPI ratings. Loads the persisted run record (Harness.ResultStore.list_run_records/1), so it works after the run process is gone — the settled-run complement to dispatch-status/dispatch-transcript (live).",
    params: [
      run_id: [
        kind: :value,
        description:
          "Run id string from dispatch-task / dispatch-await / result_store-list_run_records. Returns {:error, :not_found} when no persisted record exists for it (never recorded, or the store is disabled)."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id, task_id, verdict :approve|:reject|nil, report: string|nil, ratings: map, proposed_tasks: list}}. {:error, :not_found} for an unknown/unrecorded run_id, or {:error, reason} on a store failure."
    }
  )

  @spec verdict_detail(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def verdict_detail(run_id), do: Observation.verdict_detail(run_id)

  api(
    :recommend,
    "Recommend an agent by matching facets against the scout's per-facet competence assessment. Returns the scout's choice and rationale; callers still decide whether to dispatch.",
    params: [
      domain: [
        kind: :value,
        description:
          ~s(Capability domain string used to predict facets when :facets is omitted, e.g. "otp", "ecto", "liveview".)
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword options. Common keys: :facets (routing KEY map), :agents, :fallback_agent, :assessment_path, :result_store."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{agent, facets, strategy, rationale, scout_reasoning, matched_facet, ranked}} or {:error, reason}. strategy is :explore, :exploit, or :fallback_no_data."
    }
  )

  @spec recommend(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recommend(domain, opts \\ []), do: Resolution.recommend(domain, opts)

  defopts_tool(
    name: :assess_facets,
    description:
      "Refresh the per-facet scout competence assessment from persisted run records. Spawns the scout AI on demand; the written artifact is what dispatch-recommend reads.",
    opts_doc:
      "Keyword options. Common keys: :agents, :scout_adapter, :assessment_path, :assessment_root, :result_store, :scratch_dir.",
    returns: "{:ok, assessment_map} or {:error, reason}."
  )

  @spec assess_facets(keyword()) :: {:ok, map()} | {:error, term()}
  def assess_facets(opts \\ []), do: Resolution.assess_facets(opts)

  @doc false
  @spec recommended_adapter_for_item(String.t(), Item.t(), keyword()) ::
          {:ok, {module(), atom()}} | {:error, term()}
  def recommended_adapter_for_item(adapter, item, opts \\ []),
    do: Resolution.recommended_adapter_for_item(adapter, item, opts)

  @doc false
  @spec start_opts(pid() | nil, boolean()) :: keyword()
  def start_opts(subscriber, scrub_anthropic_key), do: Submission.start_opts(subscriber, scrub_anthropic_key)

  @doc false
  @spec run_start_opts(Item.t(), pid() | nil, boolean()) :: keyword()
  def run_start_opts(item, subscriber, scrub_anthropic_key),
    do: Submission.run_start_opts(item, subscriber, scrub_anthropic_key)

  @doc false
  @spec summarize_result(Run.Result.t()) :: RunSummary.t()
  def summarize_result(result), do: Presentation.summarize_result(result)

  @doc false
  @spec summarize_oban_job_status(Job.t()) :: map()
  def summarize_oban_job_status(job), do: Presentation.summarize_oban_job_status(job)

  @doc false
  @spec summarize_comparison(Comparison.t()) :: map()
  def summarize_comparison(comparison), do: Presentation.summarize_comparison(comparison)

  @doc false
  @spec summarize_verdict_detail(LogRecord.t()) :: map()
  def summarize_verdict_detail(record), do: Presentation.summarize_verdict_detail(record)
end
