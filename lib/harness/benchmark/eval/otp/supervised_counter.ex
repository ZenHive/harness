defmodule Harness.Benchmark.Eval.Otp.SupervisedCounter do
  @moduledoc false
  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    child_name = Keyword.get(opts, :child_name, Counter)

    children = [
      %{
        id: __MODULE__.Counter,
        start: {__MODULE__.Counter, :start_link, [[name: child_name]]},
        restart: :permanent
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec increment(atom()) :: non_neg_integer()
  def increment(name), do: __MODULE__.Counter.increment(name)

  defmodule Counter do
    @moduledoc false
    use GenServer

    @doc false
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, 0, name: name)
    end

    @doc false
    @spec increment(atom()) :: non_neg_integer()
    def increment(name), do: GenServer.call(name, :increment)

    @impl GenServer
    @spec init(non_neg_integer()) :: {:ok, non_neg_integer()}
    def init(count), do: {:ok, count}

    @impl GenServer
    @spec handle_call(:increment, GenServer.from(), non_neg_integer()) ::
            {:reply, non_neg_integer(), non_neg_integer()}
    def handle_call(:increment, _from, count), do: {:reply, count + 1, count + 1}
  end
end
