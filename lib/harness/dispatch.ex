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
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.Run.Worker, as: RunWorker
  alias Harness.Verification.Verdict
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
    "Dispatch one roadmap task for a registered project end-to-end: ingest it and start a supervised, verified run on the chosen adapter. Returns a run_id. The single JSON-native dispatch entry point for chat/MCP orchestrators.",
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
          "Executor: recommend | claude | codex | cursor | grok | antigravity | pi. recommend consults persisted capability scores and falls back safely when no data exists; explicit adapter names bypass recommendation."
      ],
      scrub_anthropic_key: [
        kind: :value,
        default: true,
        description:
          "When true (default), scrubs ANTHROPIC_API_KEY from the agent's environment so Claude dispatches use subscription OAuth instead of the metered API. Harmless for non-Claude adapters."
      ],
      review_green: [
        kind: :value,
        default: false,
        description:
          "When true, forces one cross-family reviewer pass on a green verdict for this run — the reviewer reviews the committed work against the task's acceptance criteria and fixes inline if it does not conform. Default false leaves the project-level review_green setting in control. (Replaces the deprecated semantic_gate param.)"
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{run_id: run_id}} on a started run. {:error, reason}: unknown_adapter, unknown_project, the rmap ingest reasons, or a start_run failure (e.g. worktree isolation rejection for antigravity)."
    }
  )

  @spec task(String.t(), String.t(), String.t(), boolean(), boolean()) ::
          {:ok, %{run_id: String.t()}} | {:error, error()}
  def task(project_name, task, adapter \\ @recommended_adapter, scrub_anthropic_key \\ true, review_green \\ false)
      when is_binary(project_name) and is_binary(task) and is_binary(adapter) and is_boolean(scrub_anthropic_key) and
             is_boolean(review_green) do
    with {:ok, run_id} <- enqueue_start(project_name, task, adapter, scrub_anthropic_key, review_green) do
      {:ok, %{run_id: run_id}}
    end
  end

  api(
    :await,
    "Dispatch one roadmap task and block until the run settles, returning a compact verdict summary (state, reason, per-check results) instead of a run_id to poll. The bounded blocking variant of dispatch-task — one call gets the answer. The wait is capped by timeout_ms; on timeout it returns a structured :timed_out summary (the run keeps going, observable later via run_id), never a wedged tool call.",
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
          "Executor: recommend | claude | codex | cursor | grok | antigravity | pi. recommend consults persisted capability scores and falls back safely when no data exists; explicit adapter names bypass recommendation."
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
      ],
      review_green: [
        kind: :value,
        default: false,
        description:
          "When true, forces one cross-family reviewer pass on a green verdict for this run — the reviewer reviews the committed work against the task's acceptance criteria and fixes inline if it does not conform. Default false leaves the project-level review_green setting in control. (Replaces the deprecated semantic_gate param.)"
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, summary} where summary is a settled-run map (run_id, task_id, state :done|:failed, reason, passed, verdict with per-check results, repair_attempts, diagnostics) OR a :timed_out map (run_id, state :timed_out, reason :await_timeout, timeout_ms). {:error, reason} on a dispatch failure (unknown_adapter, unknown_project, the rmap ingest reasons, or a start_run failure) — same as dispatch-task."
    }
  )

  @spec await(String.t(), String.t(), String.t(), pos_integer(), boolean(), boolean()) ::
          {:ok, map()} | {:error, error()}
  def await(
        project_name,
        task,
        adapter \\ @recommended_adapter,
        timeout_ms \\ @default_await_timeout_ms,
        scrub_anthropic_key \\ true,
        review_green \\ false
      )
      when is_binary(project_name) and is_binary(task) and is_binary(adapter) and is_integer(timeout_ms) and
             timeout_ms > 0 and is_boolean(scrub_anthropic_key) and is_boolean(review_green) do
    with {:ok, run_id} <- start(project_name, task, adapter, scrub_anthropic_key, review_green, self()) do
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
    "Snapshot one in-flight, queued, or lingering-terminal run by run_id: lifecycle state, verdict status so far, repair attempts. The live/queued counterpart to result_store-list_run_records (settled runs). Returns {:error, :not_found} only when no live run or unfinished Oban job is known.",
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
        "{:ok, map} carrying run_id, task_id, project_name, state, worktree_path, agent_os_pid, agent_kind, verdict_status, repair_attempts, reason. {:error, :not_found} for stopped/unknown runs."
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
        "{:ok, %{batch_id, task_id, total, max_concurrency, entries}} where entries is a list of per-adapter maps (adapter, run_id, state, reason, verdict, repair_attempts, duration_ms, first_attempt_failed_check_count, agent_diff_size, token_usage). {:error, reason}: no_adapters, unknown_adapter, unknown_project, the rmap ingest reasons, or a Harness.Batch failure."
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

  # --- Settled-run failure detail over JSON ---

  api(
    :verdict_detail,
    "Read the captured output of the failed checks for a SETTLED run by run_id: the actual test/credo/dialyzer/etc. stdout+stderr a JSON caller needs to see *why* a check failed. Loads the persisted run record (Harness.ResultStore.list_run_records/1), so it works after the run process is gone — the settled-run complement to dispatch-status/dispatch-transcript (live). Each check's output is tail-truncated (the diagnostic tail), flagged with truncated: true when capped. A green run yields an empty checks map.",
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
        "{:ok, %{run_id, task_id, verdict :pass|:fail|nil, failed_checks: [name], checks: %{name => %{output: string, truncated: boolean}}}}. {:error, :not_found} for an unknown/unrecorded run_id, or {:error, reason} on a store failure."
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
    "Recommend an agent for a capability domain using persisted capability scores. Returns ranked explore/exploit advice; callers still decide whether to dispatch.",
    params: [
      domain: [
        kind: :value,
        description: ~s(Capability domain string, e.g. "otp", "ecto", "liveview".)
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword options. Common keys: :agents, :corpus_version, :reference_time, :freshness_window_days, :stale_discount, :explore_unmeasured, :fallback_agent, :result_store."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{agent, domain, strategy, rationale, ranked}} or {:error, reason}. strategy is :explore, :exploit, or :fallback_no_data."
    }
  )

  @spec recommend(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recommend(domain, opts \\ []) when is_binary(domain) and is_list(opts) do
    with {:ok, domain} <- parse_domain(domain) do
      CapabilityScore.recommend(domain, opts)
    end
  end

  # Restart-resilient fire-and-forget path for `task/5`: resolve and render the
  # item now, then persist the worker job before returning the run id. The worker
  # re-ingests by task id and starts the run with the stored id when Oban executes
  # the job.
  @spec enqueue_start(String.t(), String.t(), String.t(), boolean(), boolean()) ::
          {:ok, String.t()} | {:error, error()}
  defp enqueue_start(project_name, task, @recommended_adapter, scrub_anthropic_key, review_green) do
    with {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: :claude),
         {:ok, {adapter_module, render_agent}} <- recommended_adapter_for_item(@recommended_adapter, item),
         {:ok, item} <- rerender_for_agent(item, project, render_agent),
         {:ok, run_id, _job} <-
           RunWorker.enqueue(
             project,
             item,
             adapter_module,
             run_start_opts(item, nil, scrub_anthropic_key, review_green)
           ) do
      {:ok, run_id}
    end
  end

  defp enqueue_start(project_name, task, adapter, scrub_anthropic_key, review_green) do
    with {:ok, {adapter_module, render_agent}} <- resolve_adapter(adapter),
         {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: render_agent),
         {:ok, run_id, _job} <-
           RunWorker.enqueue(
             project,
             item,
             adapter_module,
             run_start_opts(item, nil, scrub_anthropic_key, review_green)
           ) do
      {:ok, run_id}
    end
  end

  # Blocking path for `await/6`: this keeps the in-memory subscriber contract so
  # the tool call can receive the result directly. `dispatch-task` is the
  # restart-resilient fire-and-forget MCP path.
  @spec start(String.t(), String.t(), String.t(), boolean(), boolean(), pid() | nil) ::
          {:ok, String.t()} | {:error, error()}
  defp start(project_name, task, @recommended_adapter, scrub_anthropic_key, review_green, subscriber) do
    with {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: :claude),
         {:ok, {adapter_module, render_agent}} <- recommended_adapter_for_item(@recommended_adapter, item),
         {:ok, item} <- rerender_for_agent(item, project, render_agent),
         {:ok, run_id, _pid} <-
           Run.Supervisor.start_run(
             item,
             project,
             adapter_module,
             run_start_opts(item, subscriber, scrub_anthropic_key, review_green)
           ) do
      {:ok, run_id}
    end
  end

  defp start(project_name, task, adapter, scrub_anthropic_key, review_green, subscriber) do
    with {:ok, {adapter_module, render_agent}} <- resolve_adapter(adapter),
         {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: render_agent),
         {:ok, run_id, _pid} <-
           Run.Supervisor.start_run(
             item,
             project,
             adapter_module,
             run_start_opts(item, subscriber, scrub_anthropic_key, review_green)
           ) do
      {:ok, run_id}
    end
  end

  @doc false
  @spec recommended_adapter_for_item(String.t(), Item.t(), keyword()) ::
          {:ok, {module(), atom()}} | {:error, term()}
  def recommended_adapter_for_item(adapter, item, opts \\ [])

  def recommended_adapter_for_item(@recommended_adapter, %Item{} = item, opts) when is_list(opts) do
    item
    |> recommendation_domain()
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

  @spec recommendation_domain(Item.t()) :: atom()
  defp recommendation_domain(%Item{domains: [domain | _]}), do: domain
  defp recommendation_domain(%Item{}), do: :elixir

  # Build the start_run opts. Forcing a green-review pass ON is an explicit
  # `review_green: true` opt; leaving it false adds nothing so the project-level
  # `review_green` setting stays in control — passing `review_green: false`
  # would instead force it OFF. Public (@doc false) so the override threading is
  # testable without a live dispatch through the real agent CLI — same
  # testability seam as await_result/2 and summarize_comparison/1.
  @doc false
  @spec start_opts(pid() | nil, boolean(), boolean()) :: keyword()
  def start_opts(subscriber, scrub_anthropic_key, review_green) do
    opts = [subscriber: subscriber, env: scrub_env(scrub_anthropic_key)]
    if review_green, do: Keyword.put(opts, :review_green, true), else: opts
  end

  @doc false
  @spec run_start_opts(Item.t(), pid() | nil, boolean(), boolean()) :: keyword()
  def run_start_opts(%Item{} = item, subscriber, scrub_anthropic_key, review_green) do
    item
    |> Map.get(:model)
    |> case do
      model when is_binary(model) ->
        subscriber
        |> start_opts(scrub_anthropic_key, review_green)
        |> Keyword.put(:requested_model, model)

      _other ->
        start_opts(subscriber, scrub_anthropic_key, review_green)
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
      repair_attempts: result.repair_attempts,
      first_attempt_failed_check_count: result.first_attempt_failed_check_count,
      agent_diff_size: result.agent_diff_size,
      worktree_path: result.worktree_path,
      verdict: summarize_verdict(result.verdict)
    }
  end

  # The verdict summary deliberately drops each check's captured output (a check
  # can emit megabytes of test/dialyzer output) and the raw agent transcript —
  # those are not what a JSON tool result should carry. Per-check status + the
  # failed-check names are enough to act on; full output stays on the
  # %Run.Result{}/LogRecord for callers that need it.
  @spec summarize_verdict(Verdict.t() | nil) :: map() | nil
  defp summarize_verdict(nil), do: nil

  defp summarize_verdict(%Verdict{status: status, results: results}) do
    %{
      status: status,
      checks: Enum.map(results, &%{name: &1.name, status: &1.status, kind: &1.kind, exit_status: &1.exit_status}),
      failed_checks: for(result <- results, result.status == :fail, do: result.name)
    }
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
      verdict_status: status.verdict_status,
      repair_attempts: status.repair_attempts,
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
      verdict_status: nil,
      repair_attempts: 0,
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

  # Projects a settled run's LogRecord into the per-check failure-output map.
  # Public (@doc false) so the projection is testable with a hand-built
  # %LogRecord{} — same testability seam as summarize_comparison/1 above. The
  # record's check_output is already capped + JSON-safe (string keys, string/bool
  # values); this just surfaces it alongside the verdict + failed-check names.
  @doc false
  @spec summarize_verdict_detail(LogRecord.t()) :: map()
  def summarize_verdict_detail(%LogRecord{} = record) do
    %{
      run_id: record.run_id,
      task_id: record.task_id,
      verdict: record.verdict,
      failed_checks: Enum.map(record.failure_cause.failed_checks, & &1.name),
      checks: record.check_output
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
      repair_attempts: entry.repair_attempts,
      duration_ms: entry.duration_ms,
      first_attempt_failed_check_count: entry.first_attempt_failed_check_count,
      agent_diff_size: entry.agent_diff_size,
      token_usage: Map.from_struct(entry.token_usage)
    }
  end

  # Pass scalars through; inspect anything else (e.g. a {:run_crashed, _} reason)
  # so the comparison summary stays JSON-encodable. nil is an atom, so it passes.
  @spec jsonable(term()) :: term()
  defp jsonable(term) when is_atom(term) or is_binary(term) or is_number(term), do: term
  defp jsonable(term), do: inspect(term)

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
