defmodule Harness.AgentRegistry do
  @moduledoc """
  Capability and availability registry for dispatchable agent adapters.

  The registry is the orchestrator-facing gate before a run starts. It keeps the
  static adapter contract (`capabilities/0`) separate from transient runtime
  availability, such as a subscription quota being exhausted.
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
