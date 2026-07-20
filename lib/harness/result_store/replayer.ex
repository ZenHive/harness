defmodule Harness.ResultStore.Replayer do
  @moduledoc """
  Periodically replays run records spilled during settle-time persistence drift.

  The worker is mechanical: it retries every durable dead-letter entry against
  the configured result store. Expected insert failures leave entries in place;
  an operator remains responsible for applying pending migrations.
  """

  use GenServer

  alias Harness.ResultStore

  @default_interval_ms 5_000

  @type state :: %{interval_ms: pos_integer(), store: ResultStore.store()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, configured_interval_ms())
    state = %{interval_ms: interval_ms, store: Keyword.get(opts, :store, ResultStore.configured())}
    schedule_replay(0)
    {:ok, state}
  end

  @impl true
  @spec handle_info(:replay, state()) :: {:noreply, state()}
  def handle_info(:replay, state) do
    _ = ResultStore.replay_spilled(state.store)
    schedule_replay(state.interval_ms)
    {:noreply, state}
  end

  @spec configured_interval_ms() :: pos_integer()
  defp configured_interval_ms do
    Application.get_env(:harness, :result_store_replay_interval_ms, @default_interval_ms)
  end

  @spec schedule_replay(non_neg_integer()) :: reference()
  defp schedule_replay(delay_ms), do: Process.send_after(self(), :replay, delay_ms)
end
