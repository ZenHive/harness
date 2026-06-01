defmodule Harness.Benchmark.Eval.Otp.Latch do
  @moduledoc false
  @behaviour :gen_statem

  @type state :: :open | :closed

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :initial, :open)
    name = Keyword.get(opts, :name, __MODULE__)
    :gen_statem.start_link({:local, name}, __MODULE__, initial, [])
  end

  @impl :gen_statem
  @spec init(state()) :: {:ok, state(), map()}
  def init(initial) when initial in [:open, :closed], do: {:ok, initial, %{}}

  @impl :gen_statem
  @spec callback_mode() :: :handle_event_function
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  @spec handle_event(:gen_statem.event_type(), term(), state(), map()) ::
          :gen_statem.handle_event_result()
  def handle_event(:cast, :toggle, state, data), do: {:next_state, opposite(state), data}

  def handle_event(:cast, {:set, new_state}, _state, data) when new_state in [:open, :closed],
    do: {:next_state, new_state, data}

  def handle_event({:call, from}, :state, state, _data), do: {:keep_state_and_data, [{:reply, from, state}]}

  def handle_event(_type, _event, _state, data), do: {:keep_state_and_data, data}

  @spec opposite(state()) :: state()
  defp opposite(:open), do: :closed
  defp opposite(:closed), do: :open
end
