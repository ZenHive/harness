defmodule Harness.AgentRegistry do
  @moduledoc """
  Capability and availability registry for dispatchable agent adapters.

  The registry is the orchestrator-facing gate before a run starts. It keeps the
  static adapter contract (`capabilities/0`) separate from transient runtime
  availability, such as a subscription quota being exhausted.

  ## Two roles in one module

  The registry serves two cleanly separable concerns kept together for locality:

    * **Static index** — the compile-time set of dispatchable adapters
      (`agents/0`, `all/0`, `module_for_agent/1`, `agent_for_module/1`,
      `delegatable_agents/0`, `delegatable_module_for_agent/1`) and a
      lazy-memoized binary-installed probe (`installed?/1`,
      `refresh_installed/0`). Pure compile-time data plus a one-shot
      `System.find_executable/1` cache. The set is hardcoded in `@agents` and
      `@executables`; adding a new adapter is one entry per map. The single
      duplication site that audit_review.ex previously carried as its own
      `@agents` attribute is consolidated here.

    * **Transient unavailability** — `mark_unavailable/2`,
      `mark_quota_exhausted/2`, `mark_available/1`, `list_unavailable/0`,
      `available?/1`. In-memory, no persistence, clears on restart by design
      (see "Availability is a soft hint, not a contract" below).

  The two roles never share storage: the static index is module-attribute
  data plus a cache map keyed by adapter module; the transient map is keyed
  the same way but lives in its own state field. Either can be removed
  without affecting the other.

  ## Availability is a soft hint, not a contract

  Unavailability state (quota-exhausted, manually marked) lives in `GenServer`
  state only — there is no persistence, no TTL, and no replication. **A
  restart of `Harness.AgentRegistry` (BEAM restart, supervisor restart) clears
  the table**, and an adapter you knew was quota-exhausted is available again
  on the next `select/2`. This is **by design**, not a bug:

    * The registry exists as a **latency optimization** — skip a known-bad
      adapter at dispatch time so we do not burn even the first attempt on it.
    * **Correctness lives one layer below**, in Oban. A worker that hits quota
      maps the failure to `{:snooze, reason}`; the persisted job row survives
      both restarts and quota windows, and is retried later with the registry
      in whatever state it then holds (often a different adapter has come
      back).
    * Quota windows are themselves transient (typically 5h rolling for the
      major LLM providers). Persisting a quota mark across a restart would
      usually be **wrong by the time the BEAM comes back up** — the quota
      likely refilled. Persistence without a TTL is buggy; persistence with a
      TTL is a TTL design with extra storage.

  The bounded cost of a restart-clear is **at most one wasted run attempt per
  previously-marked-unavailable adapter per restart** — the next worker maps
  the resulting quota error back to `mark_quota_exhausted/2` and the registry
  re-converges. Oban's retry/snooze contract absorbs the rest.

  ## When to revisit

  If harness runs as a long-lived daemon (uptime ≥ days) and the LLM-provider
  quota windows hit often enough that wasted-first-attempts become visible at
  the dashboard, add a **TTL** to unavailability (option (c) from
  [audit-review 9b686a9b](`.audit/9b686a9-agent-registry.md`)) — set the TTL
  to match the provider's quota window (e.g. 5h for Anthropic). Do **not**
  add persistence (option (a)) without a TTL — see rationale above.

  Audit context: filed by `staged-review:audit-review` against commit
  `9b686a9b` on 2026-05-23, resolved as option (b) — "document fail-stop
  semantics, rely on Oban retry" — on 2026-05-27 (Task 40).
  """

  use GenServer

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Pi

  @quota_patterns [
    "subscription quota",
    "quota exhausted",
    "quota exceeded",
    "usage limit",
    "rate limit exceeded",
    "limit reached"
  ]

  @agents %{
    claude: Claude,
    codex: Codex,
    cursor: Cursor,
    grok: Grok,
    antigravity: Antigravity,
    pi: Pi
  }

  @module_to_agent Map.new(@agents, fn {atom, mod} -> {mod, atom} end)

  @delegatable_agents [:claude, :codex, :cursor]

  @executables %{
    Claude => "claude",
    Codex => "codex",
    Cursor => "cursor-agent",
    Grok => "grok",
    Antigravity => "agy",
    Pi => "pi"
  }

  @type agent :: :claude | :codex | :cursor | :grok | :antigravity | :pi

  @type select_error ::
          {:unsupported_capability, AgentAdapter.capability(), [module()]}
          | {:no_available_agent, [module()]}

  @type module_for_agent_error ::
          {:unsupported_agent, atom()}

  @type delegatable_module_for_agent_error ::
          {:unsupported_agent, atom()} | {:non_delegatable, atom()}

  @type agent_for_module_error ::
          {:unsupported_adapter, module()}

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl GenServer
  def init(_init_arg), do: {:ok, %{unavailable: %{}, installed: %{}}}

  @doc """
  Selects the first available adapter that supports every required capability.
  """
  @spec select(module() | [module()], keyword()) :: {:ok, module()} | {:error, select_error()}
  def select(adapters, opts \\ []) do
    adapters = List.wrap(adapters)
    required = Keyword.get(opts, :required_capabilities, [])

    case supporting_adapters(adapters, required) do
      [] ->
        {:error, {:unsupported_capability, first_missing_capability(adapters, required), adapters}}

      supported ->
        case Enum.find(supported, &available?/1) do
          nil -> {:error, {:no_available_agent, supported}}
          adapter -> {:ok, adapter}
        end
    end
  end

  @doc """
  Returns whether `adapter` currently has dispatch headroom.
  """
  @spec available?(module()) :: boolean()
  def available?(adapter) do
    GenServer.call(__MODULE__, {:available?, adapter})
  end

  @doc """
  Marks `adapter` unavailable for new work.
  """
  @spec mark_unavailable(module(), term()) :: :ok
  def mark_unavailable(adapter, reason) do
    GenServer.call(__MODULE__, {:mark_unavailable, adapter, reason})
  end

  @doc """
  Marks `adapter` unavailable because its captured output indicates quota exhaustion.
  """
  @spec mark_quota_exhausted(module(), Outcome.t()) :: :ok
  def mark_quota_exhausted(adapter, %Outcome{} = outcome) do
    mark_unavailable(adapter, {:quota_exhausted, outcome.kind})
  end

  @doc """
  Marks `adapter` available again.
  """
  @spec mark_available(module()) :: :ok
  def mark_available(adapter) do
    GenServer.call(__MODULE__, {:mark_available, adapter})
  end

  @doc """
  Lists adapters currently marked unavailable with their reasons.
  """
  @spec list_unavailable() :: [{module(), term()}]
  def list_unavailable do
    GenServer.call(__MODULE__, :list_unavailable)
  end

  @doc """
  Filters `adapters` to those whose `c:Harness.AgentAdapter.capabilities/0`
  declares the given `cost_tier`.

  The first cost-aware dispatch primitive — exposes "list available free-tier
  adapters" as a first-class query without baking in a selection policy. Pass
  `:free` to surface adapters whose dispatch consumes no metered quota; pass
  `:metered` for the paid-quota baseline.

  Pure — reads each adapter's static capability declaration. Does not consult
  the runtime unavailability map; compose with `available?/1` when you want to
  drop quota-exhausted adapters too.

      iex> Harness.AgentRegistry.filter_by_cost_tier(
      ...>   [Harness.AgentAdapter.Pi, Harness.AgentAdapter.Claude],
      ...>   :free
      ...> )
      [Harness.AgentAdapter.Pi]
  """
  @spec filter_by_cost_tier([module()], Capabilities.cost_tier()) :: [module()]
  def filter_by_cost_tier(adapters, cost_tier) when cost_tier in [:free, :metered] do
    Enum.filter(adapters, &AgentAdapter.supports?(&1, {:cost_tier, cost_tier}))
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Detects common quota-exhaustion messages in an agent outcome.
  """
  @spec quota_exhausted?(Outcome.t() | nil) :: boolean()
  def quota_exhausted?(nil), do: false

  def quota_exhausted?(%Outcome{output: output}) when is_binary(output) do
    output = String.downcase(output)
    Enum.any?(@quota_patterns, &String.contains?(output, &1))
  end

  @doc """
  Returns the full atom→module map of dispatchable adapters.

  The single source of truth for the adapter set. Adding a new adapter is one
  entry here plus one in `@executables`.
  """
  @spec agents() :: %{agent() => module()}
  def agents, do: @agents

  @doc """
  Returns the list of adapter modules — `agents/0 |> Map.values/1`.

  Convenience for enumeration (e.g. the dashboard "Adapters" panel).
  """
  @spec all() :: [module()]
  def all, do: Map.values(@agents)

  @doc """
  Returns the atom→module map for the agents `rmap delegate --to` supports.

  Currently `:claude`, `:codex`, `:cursor`. The other three adapters (Grok,
  Antigravity, Pi) ship through the two-step non-delegatable dispatch pattern;
  see `Harness.Roadmap.ingest/2` and the `harness-driver` skill.
  """
  @spec delegatable_agents() :: %{agent() => module()}
  def delegatable_agents, do: Map.take(@agents, @delegatable_agents)

  @doc """
  Resolves an agent atom to its adapter module.
  """
  @spec module_for_agent(atom()) :: {:ok, module()} | {:error, module_for_agent_error()}
  def module_for_agent(agent) when is_atom(agent) do
    case Map.fetch(@agents, agent) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_agent, agent}}
    end
  end

  @doc """
  Resolves a delegatable agent atom to its adapter module.

  Distinguishes "unknown atom" (`:unsupported_agent`) from "known but
  non-delegatable" (`:non_delegatable`) so the caller can preserve the
  existing rejection semantic of `batch.ex`, `cron/roadmap_poller.ex`, and
  `run/worker.ex`.
  """
  @spec delegatable_module_for_agent(atom()) ::
          {:ok, module()} | {:error, delegatable_module_for_agent_error()}
  def delegatable_module_for_agent(agent) when is_atom(agent) do
    cond do
      agent in @delegatable_agents -> {:ok, Map.fetch!(@agents, agent)}
      Map.has_key?(@agents, agent) -> {:error, {:non_delegatable, agent}}
      true -> {:error, {:unsupported_agent, agent}}
    end
  end

  @doc """
  Resolves an adapter module back to its agent atom.

  Inverse of `module_for_agent/1`. Useful where retry classification, logging,
  or telemetry needs the short atom form (see `Harness.Run.Worker`).
  """
  @spec agent_for_module(module()) :: {:ok, agent()} | {:error, agent_for_module_error()}
  def agent_for_module(module) when is_atom(module) do
    case Map.fetch(@module_to_agent, module) do
      {:ok, agent} -> {:ok, agent}
      :error -> {:error, {:unsupported_adapter, module}}
    end
  end

  @doc """
  Returns whether the adapter's CLI binary is present on PATH.

  Lazy-memoized — the first call probes `System.find_executable/1` and caches
  the boolean; subsequent calls return from cache. Use `refresh_installed/0`
  to invalidate after a binary install/uninstall.

  Returns `false` for unknown adapter modules.
  """
  @spec installed?(module()) :: boolean()
  def installed?(adapter) when is_atom(adapter) do
    GenServer.call(__MODULE__, {:installed?, adapter})
  end

  @doc """
  Clears the lazy `installed?/1` cache.

  Subsequent `installed?/1` calls re-probe `System.find_executable/1`.
  """
  @spec refresh_installed() :: :ok
  def refresh_installed do
    GenServer.call(__MODULE__, :refresh_installed)
  end

  @impl GenServer
  def handle_call({:available?, adapter}, _from, state) do
    {:reply, not Map.has_key?(state.unavailable, adapter), state}
  end

  def handle_call({:mark_unavailable, adapter, reason}, _from, state) do
    {:reply, :ok, put_in(state, [:unavailable, adapter], reason)}
  end

  def handle_call({:mark_available, adapter}, _from, state) do
    {:reply, :ok, update_in(state.unavailable, &Map.delete(&1, adapter))}
  end

  def handle_call(:list_unavailable, _from, state) do
    {:reply, Map.to_list(state.unavailable), state}
  end

  def handle_call({:installed?, adapter}, _from, state) do
    case Map.fetch(state.installed, adapter) do
      {:ok, cached} ->
        {:reply, cached, state}

      :error ->
        probed = probe_installed(adapter)
        {:reply, probed, put_in(state, [:installed, adapter], probed)}
    end
  end

  def handle_call(:refresh_installed, _from, state) do
    {:reply, :ok, %{state | installed: %{}}}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{unavailable: %{}, installed: %{}}}
  end

  @spec probe_installed(module()) :: boolean()
  defp probe_installed(adapter) do
    case Map.fetch(@executables, adapter) do
      {:ok, name} -> not is_nil(System.find_executable(name))
      :error -> false
    end
  end

  @spec supporting_adapters([module()], [AgentAdapter.capability()]) :: [module()]
  defp supporting_adapters(adapters, required) do
    Enum.filter(adapters, fn adapter ->
      Enum.all?(required, &AgentAdapter.supports?(adapter, &1))
    end)
  end

  @spec first_missing_capability([module()], [AgentAdapter.capability()]) :: AgentAdapter.capability() | nil
  defp first_missing_capability(_adapters, []), do: nil

  defp first_missing_capability(adapters, required) do
    Enum.find(required, fn capability ->
      Enum.all?(adapters, &(not AgentAdapter.supports?(&1, capability)))
    end)
  end
end
