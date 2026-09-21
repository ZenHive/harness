defmodule Harness.Run.Admission do
  @moduledoc "Admission fence for run invocations and graceful shutdown."
  use GenServer

  require Logger

  @spawn_grace 5_000

  @doc "Starts the invocation admission fence for a run supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Returns the shared shutdown token for state callbacks."
  @spec token(GenServer.server()) :: :atomics.atomics_ref()
  def token(server), do: GenServer.call(server, :token)

  @doc "Reports whether invocation admission has closed."
  @spec closed?(:atomics.atomics_ref()) :: boolean()
  def closed?(token), do: :atomics.get(token, 1) == 1

  @doc "Starts a supervised run only while admission is open."
  @spec start_run(GenServer.server(), Supervisor.child_spec() | tuple()) :: Supervisor.on_start_child()
  def start_run(server, child), do: GenServer.call(server, {:start_run, child}, :infinity)

  @doc "Leases permission for the calling process to spawn an agent."
  @spec acquire(GenServer.server()) :: :ok | {:error, :shutdown}
  def acquire(server), do: GenServer.call(server, :acquire)

  @doc "Releases the calling process's spawn lease after handle delivery."
  @spec release(GenServer.server()) :: :ok
  def release(server), do: GenServer.call(server, :release)

  @doc "Closes admission and waits for admitted spawns to finish or be terminated."
  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, :close, @spawn_grace + 1_000)

  @doc "Waits for outstanding spawn leases to drain after admission closes."
  @spec await(GenServer.server()) :: :ok
  def await(server), do: GenServer.call(server, :await, @spawn_grace + 1_000)

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    {:ok, %{token: :atomics.new(1, []), runs: Keyword.fetch!(opts, :runs), leases: %{}, waiters: []}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: term()
  def handle_call(:token, _from, state), do: {:reply, state.token, state}

  def handle_call(:close, from, state) do
    :atomics.put(state.token, 1, 1)
    Process.send_after(self(), :spawn_deadline, @spawn_grace)
    finish_close(%{state | waiters: [from | state.waiters]})
  end

  def handle_call(:await, from, state) do
    finish_close(%{state | waiters: [from | state.waiters]})
  end

  def handle_call(:acquire, {pid, _tag}, state) do
    if closed?(state.token) do
      {:reply, {:error, :shutdown}, state}
    else
      {:reply, :ok, %{state | leases: Map.put(state.leases, pid, Process.monitor(pid))}}
    end
  end

  def handle_call(:release, {pid, _tag} = from, state) do
    {ref, leases} = Map.pop(state.leases, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    GenServer.reply(from, :ok)
    finish_close(%{state | leases: leases})
  end

  def handle_call({:start_run, child}, _from, state) do
    reply = if closed?(state.token), do: {:error, :shutdown}, else: DynamicSupervisor.start_child(state.runs, child)
    {:reply, reply, state}
  end

  @impl true
  @spec handle_info(term(), map()) :: term()
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    finish_close(%{state | leases: Map.delete(state.leases, pid)})
  end

  def handle_info(:spawn_deadline, state) do
    Enum.each(state.leases, fn {pid, _ref} ->
      Logger.error("harness shutdown: invocation #{inspect(pid)} exceeded #{@spawn_grace}ms spawn grace")
      Process.exit(pid, :kill)
    end)

    {:noreply, state}
  end

  @spec finish_close(map()) :: {:noreply, map()}
  defp finish_close(%{leases: leases} = state) when map_size(leases) == 0 do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    {:noreply, %{state | waiters: []}}
  end

  defp finish_close(state), do: {:noreply, state}
end
