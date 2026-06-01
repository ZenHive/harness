defmodule Harness.Benchmark.Eval.Genserver.Accumulator do
  @moduledoc false
  use GenServer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, 0, name: name)
  end

  @doc false
  @spec cast(atom(), integer()) :: :ok
  def cast(name \\ __MODULE__, value) when is_integer(value), do: GenServer.cast(name, {:add, value})

  @doc false
  @spec total(atom()) :: integer()
  def total(name \\ __MODULE__), do: GenServer.call(name, :total)

  @impl GenServer
  @spec init(integer()) :: {:ok, integer()}
  def init(total), do: {:ok, total}

  @impl GenServer
  @spec handle_cast({:add, integer()}, integer()) :: {:noreply, integer()}
  def handle_cast({:add, value}, total), do: {:noreply, total + value}

  @impl GenServer
  @spec handle_call(:total, GenServer.from(), integer()) :: {:reply, integer(), integer()}
  def handle_call(:total, _from, total), do: {:reply, total, total}
end
