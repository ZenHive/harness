defmodule Harness.Benchmark.Eval.Liveview.Tally do
  @moduledoc false
  use Phoenix.LiveView

  alias Phoenix.LiveView.Socket

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket), do: {:ok, assign(socket, count: 0)}

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) ::
          {:noreply, Socket.t()}
  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
  def handle_event("dec", _params, socket), do: {:noreply, update(socket, :count, &(&1 - 1))}
  def handle_event("reset", _params, socket), do: {:noreply, assign(socket, count: 0)}

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <p data-count>{@count}</p>
    <button phx-click="inc">+</button>
    <button phx-click="dec">-</button>
    <button phx-click="reset">reset</button>
    """
  end
end
