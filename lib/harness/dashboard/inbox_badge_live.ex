defmodule Harness.Dashboard.InboxBadgeLive do
  @moduledoc "Live fleet-wide unresolved count in dashboard navigation."
  use Phoenix.LiveView, layout: false

  alias Harness.Dashboard.InboxLive
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(params, session, socket), do: InboxLive.mount(params, Map.put(session, "compact", true), socket)

  @impl true
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  defdelegate handle_info(message, socket), to: InboxLive

  @impl true
  @spec handle_async(term(), term(), Socket.t()) :: {:noreply, Socket.t()}
  defdelegate handle_async(name, result, socket), to: InboxLive

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  defdelegate render(assigns), to: InboxLive
end
