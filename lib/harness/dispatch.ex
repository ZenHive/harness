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

  ## Non-delegatable executors

  `rmap delegate --to` only renders prompts for `:claude`, `:codex`, `:cursor`.
  Grok / Antigravity / Pi are dispatched via the documented two-step: ingest
  with a delegatable render agent (`:claude`), then dispatch the ingested item
  to the real adapter module. `task/4` does this internally, so the orchestrator
  never has to know about it.
  """

  use Descripex, namespace: "/dispatch"

  alias Harness.AgentAdapter
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Run
  alias Harness.Verification.Verdict

  # Default await budget: 30 minutes. A run is minutes-to-hours of work, but a
  # blocking tool call should not park a tool-equipped LLM indefinitely — the
  # caller can override per dispatch, and the run keeps going past the budget.
  @default_await_timeout_ms 1_800_000

  # Adapter name (as the orchestrator passes it) → {adapter module, render agent}.
  # The render agent is what `rmap delegate` renders the prompt for; the adapter
  # module is what actually executes. They diverge for non-delegatable executors
  # (grok/antigravity/pi), which render via :claude but run on their own module.
  @adapters %{
    "claude" => {AgentAdapter.Claude, :claude},
    "codex" => {AgentAdapter.Codex, :codex},
    "cursor" => {AgentAdapter.Cursor, :cursor},
    "grok" => {AgentAdapter.Grok, :claude},
    "antigravity" => {AgentAdapter.Antigravity, :claude},
    "pi" => {AgentAdapter.Pi, :claude}
  }

  @typedoc "A reason `task/4` can fail with (in addition to the ingest/start_run reasons it forwards)."
  @type error ::
          {:unknown_adapter, String.t()}
          | {:unknown_project, String.t()}
          | Roadmap.error()
          | term()

  api(
    :task,
    "Dispatch one roadmap task for a registered project end-to-end: ingest it and start a supervised, verified run on the chosen adapter. Returns a run_id. The single JSON-native dispatch entry point for chat/MCP orchestrators.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry__list."
      ],
      task: [
        kind: :value,
        description:
          ~s{Task selector: a task id string (e.g. "25"), or "next" for the next pending task by rmap's D/B/U scoring.}
      ],
      adapter: [
        kind: :value,
        default: "claude",
        description:
          "Executor: claude | codex | cursor | grok | antigravity | pi. Non-delegatable executors (grok/antigravity/pi) are handled via the ingest-with-a-delegatable-agent two-step internally."
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
  def task(project_name, task, adapter \\ "claude", scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(task) and is_binary(adapter) and is_boolean(scrub_anthropic_key) do
    with {:ok, run_id} <- start(project_name, task, adapter, scrub_anthropic_key, nil) do
      {:ok, %{run_id: run_id}}
    end
  end

  api(
    :await,
    "Dispatch one roadmap task and block until the run settles, returning a compact verdict summary (state, reason, per-check results) instead of a run_id to poll. The bounded blocking variant of dispatch__task — one call gets the answer. The wait is capped by timeout_ms; on timeout it returns a structured :timed_out summary (the run keeps going, observable later via run_id), never a wedged tool call.",
    params: [
      project_name: [
        kind: :value,
        description:
          "Registered project name; resolved via Harness.ProjectRegistry.lookup/1. SOURCE valid names from project_registry__list."
      ],
      task: [
        kind: :value,
        description:
          ~s{Task selector: a task id string (e.g. "25"), or "next" for the next pending task by rmap's D/B/U scoring.}
      ],
      adapter: [
        kind: :value,
        default: "claude",
        description:
          "Executor: claude | codex | cursor | grok | antigravity | pi. Non-delegatable executors (grok/antigravity/pi) are handled via the ingest-with-a-delegatable-agent two-step internally."
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
        "{:ok, summary} where summary is a settled-run map (run_id, task_id, state :done|:failed, reason, passed, verdict with per-check results, repair_attempts, diagnostics) OR a :timed_out map (run_id, state :timed_out, reason :await_timeout, timeout_ms). {:error, reason} on a dispatch failure (unknown_adapter, unknown_project, the rmap ingest reasons, or a start_run failure) — same as dispatch__task."
    }
  )

  @spec await(String.t(), String.t(), String.t(), pos_integer(), boolean()) ::
          {:ok, map()} | {:error, error()}
  def await(project_name, task, adapter \\ "claude", timeout_ms \\ @default_await_timeout_ms, scrub_anthropic_key \\ true)
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

  # Shared dispatch path for `task/4` (subscriber nil) and `await/5` (subscriber
  # the calling process). Identical resolve → ingest → start_run flow; only the
  # subscriber differs.
  @spec start(String.t(), String.t(), String.t(), boolean(), pid() | nil) ::
          {:ok, String.t()} | {:error, error()}
  defp start(project_name, task, adapter, scrub_anthropic_key, subscriber) do
    with {:ok, {adapter_module, render_agent}} <- resolve_adapter(adapter),
         {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: render_agent),
         {:ok, run_id, _pid} <-
           Run.Supervisor.start_run(item, project, adapter_module,
             subscriber: subscriber,
             env: scrub_env(scrub_anthropic_key)
           ) do
      {:ok, run_id}
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

  @spec resolve_adapter(String.t()) :: {:ok, {module(), atom()}} | {:error, {:unknown_adapter, String.t()}}
  defp resolve_adapter(adapter) do
    case Map.fetch(@adapters, adapter) do
      {:ok, pair} -> {:ok, pair}
      :error -> {:error, {:unknown_adapter, adapter}}
    end
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
