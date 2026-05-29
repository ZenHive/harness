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
    with {:ok, {adapter_module, render_agent}} <- resolve_adapter(adapter),
         {:ok, project} <- lookup_project(project_name),
         {:ok, item} <- Roadmap.ingest(selector(task), project: project, agent: render_agent),
         {:ok, run_id, _pid} <-
           Run.Supervisor.start_run(item, project, adapter_module,
             subscriber: nil,
             env: scrub_env(scrub_anthropic_key)
           ) do
      {:ok, %{run_id: run_id}}
    end
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
