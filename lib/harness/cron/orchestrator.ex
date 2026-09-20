defmodule Harness.Cron.Orchestrator do
  @moduledoc """
  The cron dispatch orchestrator — `.harness/cron-plan.json`, read mechanically.

  Cron supplies timing; the AI decides grouping and recovery. Any task with
  persisted attempts reaches the orchestrator, including a singleton. A genuine
  first-attempt singleton may dispatch directly. History lookup failure never
  means an empty history.

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
  routed within the operator-enabled roster) under `Harness.AgentDriver` in
  a throwaway scratch cwd, and reads the artifact it wrote.
  """

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentDriver
  alias Harness.AgentRegistry
  alias Harness.AgentRules
  alias Harness.Agents
  alias Harness.Artifact
  alias Harness.CapabilityScore
  alias Harness.Config
  alias Harness.Dispatch.Attempts
  alias Harness.Project
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
  @type dispatch_entry :: %{
          required(:task_id) => String.t(),
          required(:adapter) => String.t(),
          optional(:action) => String.t(),
          optional(:source_run_id) => String.t(),
          optional(:model) => String.t(),
          optional(:reason) => String.t()
        }

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
          capability: [map()],
          agents: [map()]
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
    with {:ok, ready} <- Attempts.attach(project, ready) do
      case Application.get_env(:harness, :cron_orchestrator) do
        fun when is_function(fun, 2) -> fun.(project, ready)
        _other -> run_orchestrator(project, ready)
      end
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

    case AgentDriver.run(adapter, invocation, driver_opts()) do
      {:ok, %Outcome{}} -> read(scratch)
      {:error, reason} -> {:error, {:agent, reason}}
    end
  end

  @spec build_invocation(Project.t(), [map()], atom(), String.t()) :: Invocation.t()
  defp build_invocation(%Project{} = project, ready, agent, scratch) do
    %Invocation{
      prompt: prompt(context(project, ready)),
      cwd: scratch,
      log_tag: "cron-orchestrator-#{project.name}",
      rule_content: AgentRules.render_for_languages(project.languages),
      permission_mode: :autonomous,
      # Model-capable adapters reject a nil model at the driver gate, so the
      # orchestrator call must carry the agent's standing model like every other
      # harness invocation does.
      model: Config.agent_model(agent),
      env: Map.get(@subscription_scrubs, agent, %{})
    }
  end

  @doc """
  Assembles the full orchestrator context: the dispatchable ready set, the
  in-flight tasks (with their touches, so the plan avoids stale-base overlap),
  the project's concurrency cap, best-effort capability facts, and the agent
  roster with the operator's enabled/available switches.
  """
  @spec context(Project.t(), [map()]) :: context()
  def context(%Project{} = project, ready) when is_list(ready) do
    %{
      project: project.name,
      concurrency_cap: project.concurrency_cap,
      ready: ready,
      in_flight: in_flight_tasks(project),
      capability: capability_facts(),
      agents: agent_facts()
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
    case CapabilityScore.read_assessment() do
      {:ok, %CapabilityScore.Assessment{entries: entries}} ->
        Enum.map(entries, &capability_fact/1)

      _other ->
        []
    end
  end

  # The roster is a fact the operator controls (Agents settings + quota
  # availability); the poller drops any plan entry naming an agent outside it,
  # so the orchestrator must see it to route without losing ticks.
  @spec agent_facts() :: [map()]
  defp agent_facts do
    for %{agent: agent, enabled: enabled, available: available, model: model} <- Agents.list(),
        do: %{agent: agent, enabled: enabled, available: available, model: model}
  end

  @spec capability_fact(CapabilityScore.Entry.t()) :: map()
  defp capability_fact(%CapabilityScore.Entry{} = entry) do
    %{
      facet: entry.facet,
      winner: entry.winner,
      reasoning: entry.reasoning
    }
  end

  @doc """
  Builds the orchestrator prompt: the policy (in-flight overlap, honor
  assignee, route within the enabled roster, respect the cap) plus the context
  as embedded JSON.
  """
  @spec prompt(context()) :: String.t()
  def prompt(context) when is_map(context) do
    """
    You are the dispatch orchestrator for the harness project "#{context.project}".
    Cron has woken you for this tick's ready set. Some tasks may be first attempts
    with verified empty history; others may have prior attempts. Decide
    which tasks to dispatch in THIS wave, on which agent, and which to hold back —
    then write the plan as JSON to `#{@artifact_path}` (relative to your working
    directory) and exit. Writing that file is the whole job; you change no code.

    Your working directory is a disposable non-Git scratch directory used only
    for the plan artifact, not the project checkout. The supplied attempt facts
    are your recovery evidence source; Git probes in scratch cannot establish
    whether prior work exists.

    ## Rules

    1. The ready set below is already write-disjoint: harness serialized tasks with
       overlapping `touches`/`files_to_modify` into later ticks. Do not dispatch a task
       whose `touches`/`files_to_modify` overlap an `in_flight` task — it would rebase
       across that run's land; `skip` it with disposition "defer".
    2. Use each task's `assignee` as its agent. Route only to agents listed in
       `agents` below with `enabled: true` and `available: true`; the operator
       controls that list, and harness drops any plan entry naming an agent outside it.
       Re-route a task whose assignee is not on the list, or defer it and say why.
    3. Stay within the project concurrency cap (#{inspect(context.concurrency_cap)}),
       counting the in-flight set; when in doubt, defer rather than risk a collision.

    4. History was loaded successfully before this invocation: `attempts: []`
       means verified empty history, not unavailable history or missing recovery
       evidence. For a first attempt, choose "fresh" when the other dispatch rules
       permit it; no prior branch/origin evidence is required and no prior work is
       being discarded. Explain the first-attempt choice in reason.
       When attempts exist, read their fingerprints, reviewer reports and supplied
       Git evidence. Retain useful committed work with "resume", or choose "rereview"
       when only the reviewer gate needs running. A "fresh" choice after prior
       attempts discards prior work: justify that choice explicitly in reason.
       Select the agent and model explicitly for every dispatch.
       A task id alone is not identity: do not recover unrelated changed content.
       For prior attempts, missing required branch/origin evidence is not proof
       that no work exists; defer. Missing, malformed or unavailable history is
       never equivalent to `attempts: []`; do not infer a first attempt from it.
       Recovery of coalesced runs is unsupported; defer the whole membership.
       Do not apply a fixed retry count, error-prose classifier or escalation rule.

    ## Output schema (exact)

        {
          "dispatch": [{"task_id": "<id>", "adapter": "<agent name from the agents list>",
                        "model": "<model>", "action": "fresh|resume|rereview",
                        "source_run_id": "<required for resume/rereview; omit for fresh>",
                        "reason": "<why first attempt, or why retain or discard prior work>"}],
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
      capability: context.capability,
      agents: context.agents
    }
  end

  @doc """
  Reads and parses `.harness/cron-plan.json` from the orchestrator's working dir.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, error()}
  def read(dir) when is_binary(dir) do
    case Artifact.read(dir, @artifact_path) do
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
    for %{"task_id" => id, "adapter" => adapter} = entry <- entries,
        is_binary(id),
        is_binary(adapter),
        do: Map.merge(%{task_id: id, adapter: adapter}, decision_fields(entry))
  end

  @spec decision_fields(map()) :: map()
  defp decision_fields(entry) do
    for key <- [:action, :source_run_id, :model, :reason], Map.has_key?(entry, to_string(key)), into: %{} do
      {key, entry[to_string(key)]}
    end
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
