defmodule Harness.Dashboard.ProjectSelection do
  @moduledoc """
  Shared project-picker mechanics for per-project dashboard LiveViews
  (dep freshness, suite health): `handle_params` selection, default project,
  lookup by name, and the common checked-at timestamp format.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Harness.Project
  alias Phoenix.LiveView.Socket

  @doc "Assigns `:selected_project` from params, falling back to the first project."
  @spec handle_params(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(%{"name" => name}, socket) do
    {:noreply, assign(socket, :selected_project, name)}
  end

  def handle_params(_params, socket) do
    {:noreply, assign(socket, :selected_project, default_project_name(socket.assigns.projects))}
  end

  @doc "First registered project's name, or an empty string."
  @spec default_project_name([Project.t()]) :: String.t()
  def default_project_name([%Project{name: name} | _rest]), do: name
  def default_project_name([]), do: ""

  @doc "Finds the project by name, falling back to the first project."
  @spec selected_project([Project.t()], String.t()) :: Project.t() | nil
  def selected_project(projects, name) do
    Enum.find(projects, &(&1.name == name)) || List.first(projects)
  end

  @doc "Formats a checked-at timestamp for dashboard display."
  @spec format_checked_at(DateTime.t()) :: String.t()
  def format_checked_at(%DateTime{} = checked_at) do
    Calendar.strftime(checked_at, "%Y-%m-%d %H:%M:%S UTC")
  end
end
