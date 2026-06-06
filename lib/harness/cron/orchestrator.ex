defmodule Harness.Cron.Orchestrator do
  @moduledoc """
  The cron dispatch orchestrator — `.harness/cron-plan.json`, read mechanically.

  Cron is just a timer (mechanical); what it *triggers* when more than one task
  is dispatchable is this orchestrator AI — the smart layer that reads the full
  ready set and decides the inline/dispatch/defer grouping with real judgment.
  The earlier code-driven selector in `Harness.Cron.RoadmapPoller`
  (`@default_agent`/`assignee` `cond`) could only fan the whole batch out at once
  and defaulted unrouted work to Claude — it could not judge whether several
  tasks should batch, sequence, or wait, and that blindness produced the
  2026-06-05 stale-base collision (a 10-wide batch off one `development` snapshot
  rebased across each other's lands).

  ## The mechanical gate stays in the poller, the judgment lives here

  The poller does the pure COUNT (how many dispatchable tasks this tick) and only
  spawns the orchestrator when the count shows real upside (≥2). Counting is
  ~free and mantra-clean; the orchestrator, once woken, is given FULL CONTEXT and
  is never token-starved — constraining the smart layer would defeat the point.
  Token economy comes from the gate deciding *whether* to wake it, never from
  crippling its reasoning.

  ## The plan artifact

  The orchestrator writes this JSON before it exits and harness reads it
  mechanically — deciding NOTHING about grouping itself:

      {
        "dispatch": [{"task_id": "234", "adapter": "codex"}],
        "skip": [{"task_id": "236", "disposition": "defer",
                  "reason": "overlaps 234 on lib/harness/lander.ex"}]
      }

  `dispatch` is this wave's touch-disjoint set with a per-task adapter (the
  orchestrator's routing judgment); harness validates each task is in the ready
  set, resolves the adapter, and enqueues it — capped mechanically by the
  project's Oban queue limit, which the plan cannot override. `skip` is the
  orchestrator's witness for everything it deliberately held back (inline-able,
  deferred for overlap), logged but never enqueued. A missing/malformed artifact
  is `{:error, _}` — the poller dispatches nothing that tick and the next tick
  re-plans against the fresher base.

  ## Wave pacing is the cron cadence, not a state machine

  Harness enqueues only this tick's plan. A dispatched task is marked
  `in_progress` in rmap, so it leaves the next tick's `ready` set; a landed task
  is gone entirely. The orchestrator therefore re-plans each tick against an
  already-advanced base — "a wave lands before the next is planned" falls out of
  the cron schedule + the dedup window, with no wave-completion tracking in
  harness code.

  ## Invocation

  `plan/2` is injectable via `config :harness, :cron_orchestrator` (a
  `fun(project, ready) :: {:ok, t()} | {:error, term()}`) for tests; otherwise it
  assembles context, spawns the configured adapter (default `:codex`,
  non-Opus — honors the Opus-last roster) under `Harness.AgentAdapter.Driver` in
  a throwaway scratch cwd, and reads the artifact it wrote.
  """

  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentRegistry
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap

  @artifact_path ".harness/cron-plan.json"
  @default_adapter :codex
  @default_idle_timeout 120_000
  @default_total_timeout 300_000
  # Subscription-auth agents whose metered key harness scrubs so the orchestrator
  # call runs on the subscription, not the API — mirrors the poller's dispatch
  # scrub for the same agents.
  @subscription_scrubs %{
    claude: %{"ANTHROPIC_API_KEY" => false},
    codex: %{"OPENAI_API_KEY" => false}
  }

  @typedoc "One dispatch decision: a task to run this wave on a named adapter."
  @type dispatch_entry :: %{task_id: String.t(), adapter: String.t()}

  @typedoc "One witness for a task the orchestrator deliberately held back."
  @type skip_entry :: %{task_id: String.t(), disposition: String.t(), reason: String.t()}

  @typedoc "A parsed dispatch plan."
  @type t :: %__MODULE__{dispatch: [dispatch_entry()], skip: [skip_entry()]}

  @typedoc "The full context handed to the orchestrator AI."
  @type context :: %{
          project: String.t(),
          concurrency_cap: pos_integer() | nil,
          ready: [map()],
          in_flight: [map()],
          capability: [map()]
        }

  @typedoc "Why a plan artifact could not be produced."
  @type error :: :missing | {:malformed, term()} | {:no_adapter, term()} | {:agent, term()}

  @enforce_keys [:dispatch, :skip]
  defstruct dispatch: [], skip: []

  @doc """
  Returns the orchestrator's dispatch plan for a project's dispatchable set.

  Injectable via `config :harness, :cron_orchestrator` for tests; otherwise
  spawns the configured orchestrator adapter and reads `.harness/cron-plan.json`.
  """
  @spec plan(Project.t(), [map()]) :: {:ok, t()} | {:error, error()}
  def plan(%Project{} = project, ready) when is_list(ready) do
    case Application.get_env(:harness, :cron_orchestrator) do
      fun when is_function(fun, 2) -> fun.(project, ready)
      _other -> run_orchestrator(project, ready)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @spec run_orchestrator(Project.t(), [map()]) :: {:ok, t()} | {:error, error()}
  defp run_orchestrator(%Project{} = project, ready) do
    with {:ok, agent, adapter} <- resolve_adapter() do
      scratch = scratch_dir(project)

      try do
        invoke_and_read(project, ready, agent, adapter, scratch)
      after
        File.rm_rf(scratch)
      end
    end
  end

  @spec invoke_and_read(Project.t(), [map()], atom(), module(), String.t()) ::
          {:ok, t()} | {:error, error()}
  defp invoke_and_read(project, ready, agent, adapter, scratch) do
    invocation = build_invocation(project, ready, agent, scratch)

    case Driver.run(adapter, invocation, driver_opts()) do
      {:ok, %Outcome{}} -> read(scratch)
      {:error, reason} -> {:error, {:agent, reason}}
    end
  end

  @spec build_invocation(Project.t(), [map()], atom(), String.t()) :: Invocation.t()
  defp build_invocation(%Project{} = project, ready, agent, scratch) do
    %Invocation{
      prompt: prompt(context(project, ready)),
      cwd: scratch,
      task_id: "cron-orchestrator-#{project.name}",
      permission_mode: :autonomous,
      env: Map.get(@subscription_scrubs, agent, %{})
    }
  end

  @doc """
  Assembles the full orchestrator context: the dispatchable ready set, the
  in-flight tasks (with their touches, so the plan avoids stale-base overlap),
  the project's concurrency cap, and best-effort capability facts.
  """
  @spec context(Project.t(), [map()]) :: context()
  def context(%Project{} = project, ready) when is_list(ready) do
    %{
      project: project.name,
      concurrency_cap: project.concurrency_cap,
      ready: ready,
      in_flight: in_flight_tasks(project),
      capability: capability_facts()
    }
  end

  # In-flight = tasks rmap marks `in_progress` (set at dispatch). Resolving them
  # from rmap rather than Oban gives their `touches`/`files_to_modify` directly,
  # which is exactly what the plan needs to avoid overlapping a running task.
  @spec in_flight_tasks(Project.t()) :: [map()]
  defp in_flight_tasks(%Project{} = project) do
    case Roadmap.list(project.name, "in_progress") do
      {:ok, tasks} when is_list(tasks) -> tasks
      _other -> []
    end
  end

  @spec capability_facts() :: [map()]
  defp capability_facts do
    case ResultStore.list_capability_scores() do
      {:ok, scores} when is_list(scores) -> Enum.map(scores, &capability_fact/1)
      _other -> []
    end
  end

  @spec capability_fact(map() | struct()) :: map()
  defp capability_fact(score) do
    Map.take(Map.from_struct(score), [:agent, :domain, :score, :sample_size])
  rescue
    _error -> %{}
  end

  @doc """
  Builds the orchestrator prompt: the policy (touch-disjoint waves, honor
  assignee, Opus-last, respect the cap) plus the context as embedded JSON.
  """
  @spec prompt(context()) :: String.t()
  def prompt(context) when is_map(context) do
    """
    You are the dispatch orchestrator for the harness project "#{context.project}".
    Cron has woken you because more than one task is dispatchable this tick. Decide
    which tasks to dispatch in THIS wave, on which agent, and which to hold back —
    then write the plan as JSON to `#{@artifact_path}` (relative to your working
    directory) and exit. Writing that file is the whole job; you change no code.

    ## Hard rules (a violation here re-creates a stale-base merge collision)

    1. Never put two tasks in the same wave whose `touches` or `files_to_modify`
       sets overlap each other. Sequence them across ticks instead (dispatch one
       now, `skip` the other with disposition "defer").
    2. Never dispatch a task whose `touches`/`files_to_modify` overlap ANY in-flight
       task (see `in_flight` below) — it would rebase across that run's land.
    3. Honor each task's `assignee` as the default agent. Prefer codex/cursor/grok;
       reserve Claude (Opus) for last — do not route work to claude that another
       capable agent can take.
    4. The wave must stay within the project concurrency cap
       (#{inspect(context.concurrency_cap)}); plan a touch-disjoint subset, not the
       whole list, when in doubt. Prefer deferring to risking a collision.

    ## Output schema (exact)

        {
          "dispatch": [{"task_id": "<id>", "adapter": "<codex|cursor|grok|claude|...>"}],
          "skip": [{"task_id": "<id>", "disposition": "inline|defer", "reason": "<why>"}]
        }

    Every id in `dispatch`/`skip` must come from the ready set below. `inline` means
    the task is too small to be worth a dispatch cycle; `defer` means it waits for a
    later wave (overlap, or cap). Account for the in-flight set when sizing the wave.

    ## Context

    ```json
    #{Jason.encode!(context_payload(context), pretty: true)}
    ```
    """
  end

  @spec context_payload(context()) :: map()
  defp context_payload(context) do
    %{
      project: context.project,
      concurrency_cap: context.concurrency_cap,
      ready: context.ready,
      in_flight: context.in_flight,
      capability: context.capability
    }
  end

  @doc """
  Reads and parses `.harness/cron-plan.json` from the orchestrator's working dir.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec read(String.t()) :: {:ok, t()} | {:error, error()}
  def read(dir) when is_binary(dir) do
    path = Path.join(dir, @artifact_path)

    case File.read(path) do
      {:ok, body} -> decode(body)
      {:error, _reason} -> {:error, :missing}
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, error()}
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"dispatch" => dispatch} = map} when is_list(dispatch) ->
        {:ok, %__MODULE__{dispatch: dispatch_entries(dispatch), skip: skip_entries(Map.get(map, "skip", []))}}

      {:ok, other} ->
        {:error, {:malformed, {:unexpected_json, other}}}

      {:error, reason} ->
        {:error, {:malformed, reason}}
    end
  end

  @spec dispatch_entries([map()]) :: [dispatch_entry()]
  defp dispatch_entries(entries) do
    for %{"task_id" => id, "adapter" => adapter} <- entries,
        is_binary(id),
        is_binary(adapter),
        do: %{task_id: id, adapter: adapter}
  end

  @spec skip_entries(list()) :: [skip_entry()]
  defp skip_entries(entries) when is_list(entries) do
    for %{"task_id" => id} = entry <- entries, is_binary(id) do
      %{
        task_id: id,
        disposition: to_string(Map.get(entry, "disposition", "defer")),
        reason: to_string(Map.get(entry, "reason", ""))
      }
    end
  end

  defp skip_entries(_other), do: []

  @spec resolve_adapter() :: {:ok, atom(), module()} | {:error, {:no_adapter, term()}}
  defp resolve_adapter do
    agent = :harness |> Application.get_env(:cron_polling, []) |> Keyword.get(:orchestrator_adapter, @default_adapter)

    case AgentRegistry.delegatable_module_for_agent(agent) do
      {:ok, module} -> {:ok, agent, module}
      {:error, reason} -> {:error, {:no_adapter, reason}}
    end
  end

  @spec driver_opts() :: keyword()
  defp driver_opts do
    config = Application.get_env(:harness, :cron_polling, [])

    [
      idle_timeout: Keyword.get(config, :orchestrator_idle_timeout, @default_idle_timeout),
      total_timeout: Keyword.get(config, :orchestrator_total_timeout, @default_total_timeout)
    ]
  end

  # sobelow_skip ["Traversal.FileModule"]
  @spec scratch_dir(Project.t()) :: String.t()
  defp scratch_dir(%Project{} = project) do
    dir = Path.join(System.tmp_dir!(), "harness-cron-#{project.name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".harness"))
    dir
  end
end
