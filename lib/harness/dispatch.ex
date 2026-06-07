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

  use Descripex, namespace: "/dispatch"

  import Ecto.Query, only: [from: 2]
  import Harness.Dispatch.RunTool

  alias Harness.AgentAdapter.Registry
  alias Harness.Batch
  alias Harness.Batch.AgentEvaluation
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.CapabilityScore
  alias Harness.Cron.PendingDispatch
  alias Harness.Lander
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Review
  alias Harness.Run.Status
  alias Harness.Run.Worker, as: RunWorker
  alias Oban.Job

  # Default await budget: 30 minutes. A run is minutes-to-hours of work, but a
  # blocking tool call should not park a tool-equipped LLM indefinitely — the
  # caller can override per dispatch, and the run keeps going past the budget.
  @default_await_timeout_ms 1_800_000
  @recommended_adapter "recommend"
  @run_worker Oban.Worker.to_string(RunWorker)
  @unfinished_oban_states ~w(available scheduled executing retryable)

  @typedoc "A reason a dispatch tool can fail with (in addition to the ingest/start_run reasons it forwards)."
  @type error ::
          {:unknown_adapter, String.t()}
          | {:non_delegatable_adapter, String.t()}
          | {:unknown_project, String.t()}
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
      when is_binary(project_name) and is_binary(task) and is_binary(adapter) and is_boolean(scrub_anthropic_key) do
    with {:ok, run_id} <- enqueue_start(project_name, task, adapter, scrub_anthropic_key) do
      {:ok, %{run_id: run_id}}
    end
  end

  api(
    :await,
    "Dispatch one roadmap task and block until the run settles, returning a compact summary (state, reason, the reviewer AI's verdict) instead of a run_id to poll. The bounded blocking variant of dispatch-task — one call gets the answer. The wait is capped by timeout_ms; on timeout it returns a structured :timed_out summary (the run keeps going, observable later via run_id), never a wedged tool call.",
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

  @spec await(String.t(), String.t(), String.t(), pos_integer(), boolean()) ::
          {:ok, map()} | {:error, error()}
  def await(
        project_name,
        task,
        adapter \\ @recommended_adapter,
        timeout_ms \\ @default_await_timeout_ms,
        scrub_anthropic_key \\ true
      )
      when is_binary(project_name) and is_binary(task) and is_binary(adapter) and is_integer(timeout_ms) and
             timeout_ms > 0 and is_boolean(scrub_anthropic_key) do
    with {:ok, run_id} <- start(project_name, task, adapter, scrub_anthropic_key, self()) do
      await_result(run_id, timeout_ms)
    end
  end

  # Blocks the calling process — which MUST be the run's subscriber — until the
  # run delivers its `%Run.Result{}`, summarising it on arrival. On timeout it
  # returns a structured :timed_out summary instead of wedging. Split out so the
  # wait/summarise/timeout logic is testable without a live run (seed the mailbox
  # with a `{:harness_run, run_id, %Run.Result{}}` message).
  @doc false
  @spec await_result(String.t(), pos_integer()) :: {:ok, map()}
  def await_result(run_id, timeout_ms) when is_binary(run_id) and is_integer(timeout_ms) and timeout_ms > 0 do
    receive do
      {:harness_run, ^run_id, %Run.Result{} = result} -> {:ok, summarize(result)}
    after
      timeout_ms -> {:ok, timeout_summary(run_id, timeout_ms)}
    end
  end

  # --- Run observation / control over JSON ---
  #
  # The live/in-flight complement to result_store-list_run_records (which covers
  # SETTLED runs). status/transcript/transcript_events are macro-generated from
  # the uniform `{:ok, _} | {:error, :not_found}` Harness.Run functions; cancel
  # is hand-written because it returns a bare `:ok`. All take a run_id string —
  # the JSON-driveable half of Harness.Run's `String.t() | pid()` handle.

  api(
    :status,
    "Snapshot one in-flight, queued, or lingering-terminal run by run_id: lifecycle state and the reviewer's verdict so far. The live/queued counterpart to result_store-list_run_records (settled runs). Returns {:error, :not_found} only when no live run or unfinished Oban job is known.",
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
        "{:ok, map} carrying run_id, task_id, project_name, state, worktree_path, agent_os_pid, agent_kind, review_verdict, reason. {:error, :not_found} for stopped/unknown runs."
    }
  )

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(run_id) when is_binary(run_id) do
    case Run.status(run_id) do
      {:ok, value} -> {:ok, summarize_status(value)}
      {:error, :not_found} -> oban_job_status(run_id)
    end
  end

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
  def cancel(run_id) when is_binary(run_id) do
    :ok = Run.cancel(run_id)
    {:ok, %{run_id: run_id, cancelled: true}}
  end

  # --- Operator-mediated run recovery over JSON: hold / steer / resume ---
  #
  # The write counterparts to dispatch-cancel. Like cancel/status, the underlying
  # Harness.Run functions take a `String.t() | pid()` handle (so descripex marks
  # them :exchange_data and the Manifest drops them from the JSON surface); these
  # are the flat run-id-string wrappers. They are NOT macro-generated via
  # RunTool: hold takes a second arg, steer takes a text arg, and all three
  # return a bare `:ok` (not `{:ok, _}`), so their shapes diverge from the
  # uniform observation trio — hand-written, mirroring cancel/1.

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
  def hold(run_id, interrupt \\ false) when is_binary(run_id) and is_boolean(interrupt) do
    case Run.hold(run_id, interrupt) do
      :ok -> {:ok, %{run_id: run_id, held: true, interrupt: interrupt}}
      {:error, _reason} = error -> error
    end
  end

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
  def steer(run_id, text) when is_binary(run_id) and is_binary(text) do
    case Run.steer(run_id, text) do
      :ok -> {:ok, %{run_id: run_id, steered: true}}
      {:error, _reason} = error -> error
    end
  end

  api(
    :resume,
    "Resume a :held run, by run_id — re-enters :running with a session-resume invocation in the same worktree (any stashed steer note is applied). The JSON-native counterpart to Harness.Run.resume/1 — a mechanical lifecycle transition.",
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
        "{:ok, %{run_id, resumed: true}} on re-entry to :running. {:error, reason}: :not_held (run was not parked) or :not_found."
    }
  )

  @spec resume(String.t()) ::
          {:ok, %{run_id: String.t(), resumed: true}} | {:error, :not_held | :not_found}
  def resume(run_id) when is_binary(run_id) do
    case Run.resume(run_id) do
      :ok -> {:ok, %{run_id: run_id, resumed: true}}
      {:error, _reason} = error -> error
    end
  end

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
        "{:ok, %{run_id: new_run_id, resumed_from: old_run_id, agent: atom}} on a started run. {:error, reason}: :not_found, :not_failed, the ingest reasons, or a start_run failure."
    }
  )

  @spec resume_failed(String.t(), boolean()) ::
          {:ok, %{run_id: String.t(), resumed_from: String.t(), agent: atom() | nil}}
          | {:error, error()}
  def resume_failed(run_id, escalate \\ false) when is_binary(run_id) and is_boolean(escalate) do
    with {:ok, record} <- load_failed_record(run_id),
         {:ok, {project, item, adapter_module}} <-
           resolve_and_ingest(record.project_name, record.task_id, resume_adapter(record, escalate)),
         resumed = resume_item(item, record),
         {:ok, new_run_id, _pid} <-
           Run.Supervisor.start_run(resumed, project, adapter_module, resume_opts(resumed, run_id)) do
      {:ok, %{run_id: new_run_id, resumed_from: run_id, agent: resumed.agent}}
    end
  end

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
        "{:ok, %{run_id: new_run_id, rereviewed_from: old_run_id, agent: atom}} on a started review-only run. {:error, reason}: :not_found, :unknown_project, the ingest reasons, or a start_run failure."
    }
  )

  @spec rereview(String.t()) ::
          {:ok, %{run_id: String.t(), rereviewed_from: String.t(), agent: atom() | nil}}
          | {:error, error()}
  def rereview(run_id) when is_binary(run_id) do
    with {:ok, record} <- load_record(run_id),
         {:ok, project} <- lookup_record_project(record),
         {:ok, item} <- Roadmap.ingest(selector(record.task_id), project: project, agent: record_agent(record)),
         {:ok, new_run_id, _pid} <-
           Run.Supervisor.start_run(item, project, record.adapter, rereview_opts(item, record, run_id)) do
      {:ok, %{run_id: new_run_id, rereviewed_from: run_id, agent: item.agent}}
    end
  end

  @spec load_record(String.t()) :: {:ok, LogRecord.t()} | {:error, :not_found | term()}
  defp load_record(run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{} = record | _]} -> {:ok, record}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec load_failed_record(String.t()) ::
          {:ok, LogRecord.t()} | {:error, :not_found | :not_failed | term()}
  defp load_failed_record(run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{state: :failed} = record | _]} -> {:ok, record}
      {:ok, [%LogRecord{} | _]} -> {:error, :not_failed}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # escalate → the recommend sentinel (capability-scored routing); otherwise the
  # original agent. A record with no recorded agent also falls back to recommend.
  # Public (@doc false) so the routing is testable without a live dispatch — the
  # same testability seam as run_start_opts/3.
  @doc false
  @spec resume_adapter(LogRecord.t(), boolean()) :: String.t()
  def resume_adapter(_record, true), do: @recommended_adapter

  def resume_adapter(%LogRecord{agent: agent}, false) when is_atom(agent) and not is_nil(agent), do: Atom.to_string(agent)

  def resume_adapter(%LogRecord{}, false), do: @recommended_adapter

  # Inject the prior attempt's failure report into the freshly-rendered prompt so
  # the resumed implementer knows what to fix; the commits themselves arrive via
  # the base_ref branch, not the prompt. Public (@doc false) for the same seam.
  @doc false
  @spec resume_item(Item.t(), LogRecord.t()) :: Item.t()
  def resume_item(%Item{} = item, %LogRecord{} = record) do
    %{item | prompt: item.prompt <> "\n\n" <> prior_attempt_section(record)}
  end

  @spec prior_attempt_section(LogRecord.t()) :: String.t()
  defp prior_attempt_section(%LogRecord{review_report: report}) when is_binary(report) and report != "" do
    """
    ## Prior attempt failed — reviewer report

    #{report}

    The prior attempt's commits are already present (this run branches off them). Address the issues above and finish the task.
    """
  end

  defp prior_attempt_section(%LogRecord{reason: reason}) do
    """
    ## Prior attempt failed

    The previous run did not complete: #{resume_reason_text(reason)}

    The prior attempt's commits are already present (this run branches off them). Continue from there and finish the task.
    """
  end

  @spec resume_reason_text(Run.Result.reason()) :: String.t()
  defp resume_reason_text({tag, detail}) when tag in [:review_stuck, :review_rejected] and is_binary(detail), do: detail

  defp resume_reason_text(reason), do: inspect(reason)

  # base_ref branches the resumed run off the retained failed branch so the prior
  # commits are the starting point (the resume's headline cost saving). Public
  # (@doc false) so the base_ref threading is testable without a live dispatch.
  @doc false
  @spec resume_opts(Item.t(), String.t()) :: keyword()
  def resume_opts(%Item{} = item, old_run_id) do
    item
    |> run_start_opts(nil, true)
    |> Keyword.put(:base_ref, "harness/" <> old_run_id)
  end

  @doc false
  @spec rereview_opts(Item.t(), LogRecord.t(), String.t()) :: keyword()
  def rereview_opts(%Item{} = item, %LogRecord{} = record, old_run_id) do
    item
    |> run_start_opts(nil, true)
    |> Keyword.put(:base_ref, "harness/" <> old_run_id)
    |> Keyword.put(:review_only?, true)
    |> Keyword.put(:review_only_agent_diff_size, record.agent_diff_size)
  end

  @spec lookup_record_project(LogRecord.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t() | nil}}
  defp lookup_record_project(%LogRecord{project_name: project_name}) when is_binary(project_name) do
    lookup_project(project_name)
  end

  defp lookup_record_project(%LogRecord{project_name: project_name}), do: {:error, {:unknown_project, project_name}}

  @spec record_agent(LogRecord.t()) :: atom()
  defp record_agent(%LogRecord{agent: agent}) when is_atom(agent) and not is_nil(agent), do: agent
  defp record_agent(%LogRecord{}), do: :claude

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
  def reland(run_id) when is_binary(run_id) do
    Lander.enqueue(run_id)
  end

  # --- Manual-approval cron dispatch over JSON: pending / approve (Task 237) ---
  #
  # A project whose cron dispatch mode is :manual (Harness.Cron.Settings) does NOT
  # auto-enqueue an autonomously-selected run — the poller parks the resolved
  # decision (task id + adapter + env scrub) in Harness.Cron.PendingDispatch and
  # fires a witness event. These two tools are the operator surface: list what is
  # parked, then approve one to drain it into the normal implement->review->land
  # loop. ONLY the cron path is gated; dispatch-task / dispatch-await are not (the
  # operator already chose to issue those). The gate keys solely off the per-
  # project mode flag — no "is this run high-stakes" classifier.

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
  def pending(project_name \\ nil) when is_nil(project_name) or is_binary(project_name) do
    records =
      PendingDispatch.list()
      |> filter_pending(project_name)
      |> Enum.map(&summarize_pending/1)

    {:ok, %{pending: records}}
  end

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
  def approve(pending_id) when is_binary(pending_id) do
    case PendingDispatch.approve(pending_id) do
      {:ok, %{adapter: adapter} = result} -> {:ok, %{result | adapter: inspect(adapter)}}
      {:error, _reason} = error -> error
    end
  end

  # --- Project registration over JSON ---
  #
  # Harness.ProjectRegistry.register/1 takes a %Harness.Project{} struct
  # (:exchange_data — off the JSON surface). This is the flat scalar entry point:
  # it assembles the struct through the registry's validated builder so a runtime
  # registration behaves identically to a config :harness, :projects entry. The
  # rarer struct fields (landing_policy, target_branch, pollution_allowlist) are
  # intentionally NOT exposed here — register those via config or the project_eval
  # struct path (see docs/orchestrator-surface-inventory.md § Omissions).

  api(
    :register_project,
    "Register a project for dispatch from JSON scalars: build a validated %Harness.Project{} (with path expansion, same as a config entry) and register it. The JSON-native counterpart to Harness.ProjectRegistry.register/1. Runtime registration does NOT survive a BEAM restart unless :repo_enabled — for durable registration use config :harness, :projects.",
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
      check_command: [
        kind: :value,
        default: nil,
        description:
          ~s{Optional free-text hint handed to the reviewer AI (e.g. "mix precommit"). Harness never runs it; the reviewer runs the project's checks itself.}
      ],
      concurrency_cap: [
        kind: :value,
        default: nil,
        description: "Optional per-project max concurrent runs (the project's Oban queue limit). nil leaves the default."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{name: name}} on success. {:error, reason}: {:invalid_source_type, value}, {:invalid_project, _} (missing/invalid field), or {:duplicate, name}."
    }
  )

  @spec register_project(String.t(), String.t(), String.t(), String.t(), String.t() | nil, pos_integer() | nil) ::
          {:ok, %{name: String.t()}} | {:error, term()}
  def register_project(name, source_type, source_location, roadmap_path, check_command \\ nil, concurrency_cap \\ nil)
      when is_binary(name) and is_binary(source_type) and is_binary(source_location) and is_binary(roadmap_path) do
    with {:ok, source} <- build_source(source_type, source_location),
         attrs = [
           name: name,
           source: source,
           roadmap_path: roadmap_path,
           check_command: check_command,
           concurrency_cap: concurrency_cap
         ],
         :ok <- ProjectRegistry.register(attrs) do
      {:ok, %{name: name}}
    end
  end

  @spec build_source(String.t(), String.t()) ::
          {:ok, Project.source()} | {:error, {:invalid_source_type, String.t()}}
  defp build_source("local", location), do: {:ok, {:local, location}}
  defp build_source("github", location), do: {:ok, {:github, location}}
  defp build_source(other, _location), do: {:error, {:invalid_source_type, other}}

  # --- Fan-out over JSON: whole-bundle dispatch + same-task A/B compare ---

  api(
    :bundle,
    "Fan out the next session-sized bundle of pending roadmap tasks for a registered project: ingest each task and enqueue one Oban-backed, restart-resilient run job per task on the chosen delegatable adapter (project-scoped queue, per-project concurrency cap). Fire-and-forget — returns the ingested task ids and Oban job ids; observe each run later via dispatch-status / result_store-list_run_records. The JSON-native counterpart to Harness.Roadmap.next_bundle/1 + Harness.Batch.dispatch/2.",
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
        "{:ok, %{bundle: bundle_meta | nil, task_ids: [string], job_ids: [integer], dispatched: integer}}. {:error, reason}: unknown_adapter, non_delegatable_adapter, unknown_project, the rmap next_bundle reasons, or a Harness.Batch.dispatch failure."
    }
  )

  @spec bundle(String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, error()}
  def bundle(project_name, adapter \\ "claude", scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(adapter) and is_boolean(scrub_anthropic_key) do
    with {:ok, {_module, render_agent}} <- resolve_delegatable_adapter(adapter),
         {:ok, project} <- lookup_project(project_name),
         {:ok, %{bundle: bundle_meta, tasks: tasks}} <- Roadmap.next_bundle(project_name),
         {:ok, items} <- ingest_bundle(tasks, project, render_agent),
         {:ok, jobs} <- Batch.dispatch(project, items, env: scrub_env(scrub_anthropic_key)) do
      {:ok,
       %{
         bundle: bundle_meta,
         task_ids: Enum.map(items, & &1.id),
         job_ids: Enum.map(jobs, & &1.id),
         dispatched: length(jobs)
       }}
    end
  end

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
        "{:ok, %{batch_id, task_id, total, max_concurrency, entries}} where entries is a list of per-adapter maps (adapter, run_id, state, reason, verdict :approve|:reject|nil, reviewer_diff_size, duration_ms, agent_diff_size, token_usage). {:error, reason}: no_adapters, unknown_adapter, unknown_project, the rmap ingest reasons, or a Harness.Batch failure."
    }
  )

  @spec compare(String.t(), String.t(), [String.t()], boolean()) :: {:ok, map()} | {:error, error()}
  def compare(project_name, task, adapters, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(task) and is_list(adapters) and is_boolean(scrub_anthropic_key) do
    with {:ok, modules} <- resolve_adapter_modules(adapters),
         {:ok, project} <- lookup_project(project_name),
         # Render once, for claude, on purpose: every adapter must run the
         # identical prompt for the A/B comparison to be fair — this is not the
         # old non-delegatable two-step (rmap now renders natively for all six).
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: :claude),
         {:ok, %Comparison{} = comparison} <-
           AgentEvaluation.compare(item, project, modules, env: scrub_env(scrub_anthropic_key)) do
      {:ok, summarize_comparison(comparison)}
    end
  end

  # --- Settled-run review detail over JSON ---

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
        "{:ok, %{run_id, task_id, verdict :approve|:reject|nil, report: string|nil, ratings: map}}. {:error, :not_found} for an unknown/unrecorded run_id, or {:error, reason} on a store failure."
    }
  )

  @spec verdict_detail(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def verdict_detail(run_id) when is_binary(run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{} = record | _]} -> {:ok, summarize_verdict_detail(record)}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

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
  def recommend(domain, opts \\ []) when is_binary(domain) and is_list(opts) do
    with {:ok, domain} <- parse_domain(domain) do
      facets = Keyword.get(opts, :facets, CapabilityScore.facets_from_domain(domain))
      CapabilityScore.recommend(facets, opts)
    end
  end

  defopts_tool(
    name: :assess_facets,
    description:
      "Refresh the per-facet scout competence assessment from persisted run records. Spawns the scout AI on demand; the written artifact is what dispatch-recommend reads.",
    opts_doc:
      "Keyword options. Common keys: :agents, :scout_adapter, :assessment_path, :assessment_root, :result_store, :scratch_dir.",
    returns: "{:ok, assessment_map} or {:error, reason}."
  )

  @spec assess_facets(keyword()) :: {:ok, map()} | {:error, term()}
  def assess_facets(opts \\ []) when is_list(opts) do
    case CapabilityScore.refresh(opts) do
      {:ok, assessment} -> {:ok, summarize_assessment(assessment)}
      {:error, _reason} = error -> error
    end
  end

  # Restart-resilient fire-and-forget path for `task/4`: resolve and render the
  # item now, then persist the worker job before returning the run id. The worker
  # re-ingests by task id and starts the run with the stored id when Oban executes
  # the job.
  @spec enqueue_start(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, error()}
  defp enqueue_start(project_name, task, adapter, scrub_anthropic_key) do
    with {:ok, {project, item, adapter_module}} <- resolve_and_ingest(project_name, task, adapter),
         {:ok, run_id, _job} <-
           RunWorker.enqueue(project, item, adapter_module, run_start_opts(item, nil, scrub_anthropic_key)) do
      {:ok, run_id}
    end
  end

  # Blocking path for `await/5`: this keeps the in-memory subscriber contract so
  # the tool call can receive the result directly. `dispatch-task` is the
  # restart-resilient fire-and-forget MCP path.
  @spec start(String.t(), String.t(), String.t(), boolean(), pid() | nil) ::
          {:ok, String.t()} | {:error, error()}
  defp start(project_name, task, adapter, scrub_anthropic_key, subscriber) do
    with {:ok, {project, item, adapter_module}} <- resolve_and_ingest(project_name, task, adapter),
         {:ok, run_id, _pid} <-
           Run.Supervisor.start_run(
             item,
             project,
             adapter_module,
             run_start_opts(item, subscriber, scrub_anthropic_key)
           ) do
      {:ok, run_id}
    end
  end

  # The single resolve → ingest pipeline shared by enqueue_start/4 and start/5,
  # so the adapter-resolution + render logic exists exactly once: a bug fix here
  # is one edit, not four. The `recommend` sentinel ingests for claude, scores a
  # recommendation off the item, then re-renders for the chosen agent; a concrete
  # adapter resolves first and ingests rendered for that agent directly.
  @spec resolve_and_ingest(String.t(), String.t(), String.t()) ::
          {:ok, {Project.t(), Item.t(), module()}} | {:error, error()}
  defp resolve_and_ingest(project_name, task, @recommended_adapter) do
    with {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: :claude),
         {:ok, {adapter_module, render_agent}} <- recommended_adapter_for_item(@recommended_adapter, item),
         {:ok, item} <- rerender_for_agent(item, project, render_agent) do
      {:ok, {project, item, adapter_module}}
    end
  end

  defp resolve_and_ingest(project_name, task, adapter) do
    with {:ok, {adapter_module, render_agent}} <- resolve_adapter(adapter),
         {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: render_agent) do
      {:ok, {project, item, adapter_module}}
    end
  end

  @doc false
  @spec recommended_adapter_for_item(String.t(), Item.t(), keyword()) ::
          {:ok, {module(), atom()}} | {:error, term()}
  def recommended_adapter_for_item(adapter, item, opts \\ [])

  def recommended_adapter_for_item(@recommended_adapter, %Item{} = item, opts) when is_list(opts) do
    item
    |> predict_facets()
    |> CapabilityScore.recommend(opts)
    |> case do
      {:ok, %{agent: agent}} -> resolve_adapter(Atom.to_string(agent))
      {:error, _reason} = error -> error
    end
  end

  def recommended_adapter_for_item(adapter, %Item{}, opts) when is_binary(adapter) and is_list(opts) do
    resolve_adapter(adapter)
  end

  @spec rerender_for_agent(Item.t(), Project.t(), atom()) :: {:ok, Item.t()} | {:error, error()}
  defp rerender_for_agent(%Item{agent: agent} = item, _project, agent), do: {:ok, item}

  defp rerender_for_agent(%Item{} = item, %Project{} = project, render_agent) do
    Roadmap.ingest({:id, item.id}, project: project, agent: render_agent)
  end

  @spec predict_facets(Item.t()) :: map()
  defp predict_facets(%Item{domains: [domain | _]}), do: CapabilityScore.facets_from_domain(domain)
  defp predict_facets(%Item{}), do: %{}

  @spec summarize_assessment(CapabilityScore.Assessment.t()) :: map()
  defp summarize_assessment(%CapabilityScore.Assessment{} = assessment) do
    %{
      assessed_at: assessment.assessed_at,
      record_count: assessment.record_count,
      entries:
        Enum.map(assessment.entries, fn %CapabilityScore.Entry{} = entry ->
          %{
            facet: entry.facet,
            winner: entry.winner,
            reasoning: entry.reasoning,
            by_agent: entry.by_agent
          }
        end)
    }
  end

  # Build the start_run opts. Public (@doc false) so the secret-scrub threading
  # is testable without a live dispatch through the real agent CLI — same
  # testability seam as await_result/2 and summarize_comparison/1.
  @doc false
  @spec start_opts(pid() | nil, boolean()) :: keyword()
  def start_opts(subscriber, scrub_anthropic_key) do
    [subscriber: subscriber, env: scrub_env(scrub_anthropic_key)]
  end

  # start_opts plus the task's pinned model (when present) as :requested_model.
  @doc false
  @spec run_start_opts(Item.t(), pid() | nil, boolean()) :: keyword()
  def run_start_opts(%Item{} = item, subscriber, scrub_anthropic_key) do
    item
    |> Map.get(:model)
    |> case do
      model when is_binary(model) ->
        subscriber
        |> start_opts(scrub_anthropic_key)
        |> Keyword.put(:requested_model, model)

      _other ->
        start_opts(subscriber, scrub_anthropic_key)
    end
  end

  @spec summarize(Run.Result.t()) :: map()
  defp summarize(%Run.Result{} = result) do
    %{
      run_id: result.run_id,
      task_id: result.task_id,
      state: result.state,
      reason: result.reason,
      passed: result.state == :done,
      agent_diff_size: result.agent_diff_size,
      reviewer_diff_size: result.reviewer_diff_size,
      worktree_path: result.worktree_path,
      review: summarize_review(result.review)
    }
  end

  # The review summary carries the reviewer AI's full verdict artifact — the
  # decision, its prose report, and its implementer KPI ratings. The raw agent
  # transcript stays on the %Run.Result{}/LogRecord for callers that need it.
  @spec summarize_review(Review.t() | nil) :: map() | nil
  defp summarize_review(nil), do: nil

  defp summarize_review(%Review{verdict: verdict, report: report, ratings: ratings}) do
    %{verdict: verdict, report: report, ratings: ratings}
  end

  # Summarizers for the macro-generated run-observation tools. Each projects a
  # Harness.Run payload into a JSON-safe map (no structs, no tuples).
  @spec summarize_status(Status.t()) :: map()
  defp summarize_status(%Status{} = status) do
    %{
      run_id: status.run_id,
      task_id: status.task_id,
      project_name: status.project_name,
      state: status.state,
      worktree_path: status.worktree_path,
      agent_os_pid: status.agent_os_pid,
      agent_kind: status.agent_kind,
      review_verdict: status.review_verdict,
      reason: status.reason
    }
  end

  @spec oban_job_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp oban_job_status(run_id) do
    case lookup_oban_run_job(run_id) do
      {:ok, %Job{} = job} -> {:ok, summarize_oban_job_status(job)}
      {:error, :not_found} = error -> error
    end
  end

  @doc false
  @spec summarize_oban_job_status(Job.t()) :: map()
  def summarize_oban_job_status(%Job{} = job) do
    args = job.args || %{}

    %{
      run_id: fetch_arg(args, :run_id),
      task_id: fetch_arg(args, :item_id),
      project_name: fetch_arg(args, :project_name),
      state: :dispatched,
      worktree_path: nil,
      agent_os_pid: nil,
      agent_kind: nil,
      review_verdict: nil,
      reason: {:oban_job, job.state},
      oban_job_id: job.id,
      oban_state: job.state,
      queue: job.queue
    }
  end

  @spec lookup_oban_run_job(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  defp lookup_oban_run_job(run_id) do
    case Application.get_env(:harness, :oban_run_job_lookup) do
      fun when is_function(fun, 1) -> fun.(run_id)
      _other -> query_oban_run_job(run_id)
    end
  end

  @spec query_oban_run_job(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  defp query_oban_run_job(run_id) do
    query =
      from(job in Job,
        where:
          job.worker == ^@run_worker and job.state in ^@unfinished_oban_states and
            fragment("?->>? = ?", job.args, "run_id", ^run_id),
        order_by: [desc: job.inserted_at],
        limit: 1
      )

    case Harness.Repo.one(query) do
      %Job{} = job -> {:ok, job}
      nil -> {:error, :not_found}
    end
  rescue
    _error -> {:error, :not_found}
  end

  @spec fetch_arg(map(), atom()) :: term()
  defp fetch_arg(args, key) when is_map(args), do: Map.get(args, Atom.to_string(key), Map.get(args, key))

  @spec summarize_transcript(%{buffer: binary(), seq: non_neg_integer()}) :: map()
  defp summarize_transcript(%{buffer: buffer, seq: seq}), do: %{transcript: buffer, seq: seq}

  @spec summarize_transcript_events(%{
          events: [{atom(), map()}],
          agent_kind: atom() | nil,
          seq: non_neg_integer()
        }) :: map()
  defp summarize_transcript_events(%{events: events, agent_kind: agent_kind, seq: seq}) do
    %{events: Enum.map(events, &event_to_map/1), agent_kind: agent_kind, seq: seq}
  end

  # Parser events are {type, payload} tuples — not JSON-encodable. Flatten each
  # to its payload map tagged with the :type so the whole tool result serializes.
  @spec event_to_map({atom(), map()}) :: map()
  defp event_to_map({type, payload}) when is_map(payload), do: Map.put(payload, :type, type)

  @spec timeout_summary(String.t(), pos_integer()) :: map()
  defp timeout_summary(run_id, timeout_ms) do
    %{
      run_id: run_id,
      state: :timed_out,
      reason: :await_timeout,
      passed: false,
      timeout_ms: timeout_ms,
      note:
        "The await budget elapsed before the run settled. The run was NOT cancelled and keeps going; observe it later via run_id (Harness.Run.status/1 or the recorded run records) or cancel it with Harness.Run.cancel/1."
    }
  end

  # Bundle dispatch is Oban-backed and resolves each job's executor from the
  # ingested item's render agent. rmap renders natively for all six adapters, so
  # all six pass; the guard remains in case a future adapter is registered
  # without a matching `delegate --to` target (see Registry.delegatable?/1).
  @spec resolve_delegatable_adapter(String.t()) ::
          {:ok, {module(), atom()}} | {:error, {:unknown_adapter | :non_delegatable_adapter, String.t()}}
  defp resolve_delegatable_adapter(adapter) do
    case resolve_adapter(adapter) do
      {:ok, pair} ->
        if Registry.delegatable?(adapter),
          do: {:ok, pair},
          else: {:error, {:non_delegatable_adapter, adapter}}

      {:error, _reason} = error ->
        error
    end
  end

  # Ingest each bundle task into a %Roadmap.Item{}, halting on the first failure.
  # rmap emits task ids as JSON (string or integer); coerce to the string id
  # `Roadmap.ingest({:id, _})` requires.
  @spec ingest_bundle([map()], Project.t(), atom()) :: {:ok, [Item.t()]} | {:error, error()}
  defp ingest_bundle(tasks, project, render_agent) do
    tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, items} ->
      case Roadmap.ingest({:id, to_string(task["id"])}, project: project, agent: render_agent) do
        {:ok, item} -> {:cont, {:ok, [item | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  # Resolve a non-empty list of executor names to adapter modules for a same-task
  # A/B run. All six executors are valid here — run_pinned takes modules directly.
  @spec resolve_adapter_modules([String.t()]) :: {:ok, [module()]} | {:error, error()}
  defp resolve_adapter_modules([]), do: {:error, :no_adapters}

  defp resolve_adapter_modules(adapters) do
    adapters
    |> Enum.reduce_while({:ok, []}, fn adapter, {:ok, modules} ->
      case resolve_adapter(adapter) do
        {:ok, {module, _render_agent}} -> {:cont, {:ok, [module | modules]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      {:error, _reason} = error -> error
    end
  end

  # Projects an A/B Comparison into a JSON-safe map. Public (@doc false) so the
  # struct→map projection is testable without a live A/B run — same testability
  # seam as await_result/2 above.
  @doc false
  @spec summarize_comparison(Comparison.t()) :: map()
  def summarize_comparison(%Comparison{} = comparison) do
    %{
      batch_id: comparison.batch_id,
      task_id: comparison.task_id,
      total: comparison.total,
      max_concurrency: comparison.max_concurrency,
      entries: Enum.map(comparison.entries, &summarize_entry/1)
    }
  end

  # Projects a settled run's LogRecord into the reviewer-verdict detail map.
  # Public (@doc false) so the projection is testable with a hand-built
  # %LogRecord{} — same testability seam as summarize_comparison/1 above. The
  # record's review_report/review_ratings are persisted verbatim from the
  # reviewer's .harness/review.json; this just surfaces them with the decision.
  @doc false
  @spec summarize_verdict_detail(LogRecord.t()) :: map()
  def summarize_verdict_detail(%LogRecord{} = record) do
    %{
      run_id: record.run_id,
      task_id: record.task_id,
      verdict: record.verdict,
      report: record.review_report,
      ratings: record.review_ratings
    }
  end

  # Project one adapter's A/B metrics into a JSON-safe map: the module to a
  # readable name, the token usage struct to a plain map, the run reason through
  # jsonable/1 (a crash reason can be a tagged tuple).
  @spec summarize_entry(Entry.t()) :: map()
  defp summarize_entry(%Entry{} = entry) do
    %{
      adapter: inspect(entry.adapter),
      run_id: entry.run_id,
      state: entry.state,
      reason: jsonable(entry.reason),
      verdict: entry.verdict,
      reviewer_diff_size: entry.reviewer_diff_size,
      duration_ms: entry.duration_ms,
      agent_diff_size: entry.agent_diff_size,
      token_usage: Map.from_struct(entry.token_usage)
    }
  end

  # Pass scalars through; inspect anything else (e.g. a {:run_crashed, _} reason)
  # so the comparison summary stays JSON-encodable. nil is an atom, so it passes.
  @spec jsonable(term()) :: term()
  defp jsonable(term) when is_atom(term) or is_binary(term) or is_number(term), do: term
  defp jsonable(term), do: inspect(term)

  @spec filter_pending([PendingDispatch.t()], String.t() | nil) :: [PendingDispatch.t()]
  defp filter_pending(records, nil), do: records
  defp filter_pending(records, project_name), do: Enum.filter(records, &(&1.project_name == project_name))

  # Projects a parked decision into a JSON-safe map: the adapter module to a
  # readable name, the parked_at timestamp to ISO8601.
  @spec summarize_pending(PendingDispatch.t()) :: map()
  defp summarize_pending(%PendingDispatch{} = record) do
    %{
      id: record.id,
      project_name: record.project_name,
      task_id: record.task_id,
      adapter: inspect(record.adapter),
      parked_at: DateTime.to_iso8601(record.parked_at)
    }
  end

  @spec resolve_adapter(String.t()) :: {:ok, {module(), atom()}} | {:error, {:unknown_adapter, String.t()}}
  defp resolve_adapter(adapter), do: Registry.resolve(adapter)

  @spec parse_domain(String.t()) :: {:ok, atom()} | {:error, {:unknown_domain, String.t()}}
  defp parse_domain(":" <> domain), do: parse_domain(domain)

  # Domains are part of harness's static atom vocabulary; do not create atoms
  # from arbitrary MCP input.
  defp parse_domain(domain) do
    {:ok, String.to_existing_atom(domain)}
  rescue
    ArgumentError -> {:error, {:unknown_domain, domain}}
  end

  @spec lookup_project(String.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t()}}
  defp lookup_project(project_name) do
    case ProjectRegistry.lookup(project_name) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _} -> {:error, {:unknown_project, project_name}}
    end
  end

  @spec selector(String.t()) :: Roadmap.selector()
  defp selector("next"), do: :next
  defp selector(id), do: {:id, id}

  @spec scrub_env(boolean()) :: %{optional(String.t()) => false}
  defp scrub_env(true), do: %{"ANTHROPIC_API_KEY" => false}
  defp scrub_env(false), do: %{}
end
