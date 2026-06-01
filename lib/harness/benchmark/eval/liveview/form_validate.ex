defmodule Harness.Benchmark.Eval.Liveview.FormValidate do
  @moduledoc false
  use Phoenix.LiveView

  alias Phoenix.LiveView.Socket

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, assign(socket, name: "", valid?: false, error: nil, saved: nil)}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) ::
          {:noreply, Socket.t()}
  def handle_event("validate", %{"name" => name}, socket) do
    name = String.trim(name)
    {:noreply, assign(socket, name: name, valid?: valid_name?(name), error: error_for(name))}
  end

  def handle_event("save", %{"name" => name}, socket) do
    name = String.trim(name)

    if valid_name?(name) do
      {:noreply, assign(socket, name: name, valid?: true, error: nil, saved: name)}
    else
      {:noreply, assign(socket, name: name, valid?: false, error: error_for(name), saved: nil)}
    end
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <form phx-change="validate" phx-submit="save">
      <input name="name" value={@name} />
      <button type="submit">save</button>
    </form>
    <p :if={@error} data-error>{@error}</p>
    <p :if={@saved} data-saved>{@saved}</p>
    """
  end

  @spec valid_name?(String.t()) :: boolean()
  defp valid_name?(name), do: name != ""

  @spec error_for(String.t()) :: String.t() | nil
  defp error_for(""), do: "name is required"
  defp error_for(_name), do: nil
end
