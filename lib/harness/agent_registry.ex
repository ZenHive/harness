defmodule Harness.AgentRegistry do
  @moduledoc """
  Capability and availability registry for dispatchable agent adapters.

  The registry is the orchestrator-facing gate before a run starts. It keeps the
  static adapter contract (`capabilities/0`) separate from transient runtime
  availability, such as a subscription quota being exhausted.

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
  alias Harness.AgentAdapter.Outcome

  @quota_patterns [
    "subscription quota",
    "quota exhausted",
    "quota exceeded",
    "usage limit",
    "rate limit exceeded",
    "limit reached"
  ]

  @type select_error ::
          {:unsupported_capability, AgentAdapter.capability(), [module()]}
          | {:no_available_agent, [module()]}

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl GenServer
  def init(_init_arg), do: {:ok, %{unavailable: %{}}}

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

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{unavailable: %{}}}
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
