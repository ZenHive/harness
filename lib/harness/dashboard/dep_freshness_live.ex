defmodule Harness.Dashboard.DepFreshnessLive do
  @moduledoc """
  Per-project dependency freshness panel (`/harness/deps`).

  Displays raw provider facts — dependency rows, outdated count, and the last
  scan timestamp. Harness counts and renders only; it never recommends upgrades.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.DepFreshness
  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @tick_interval_ms 30_000

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_tick()

    projects = ProjectRegistry.list()

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:snapshots, snapshots_by_project(projects))}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(%{"name" => name}, _uri, socket) do
    {:noreply, assign(socket, :selected_project, name)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_project, default_project_name(socket.assigns.projects))}
  end

  @impl Phoenix.LiveView
  @spec handle_info(:deps_tick, Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(:deps_tick, socket) do
    schedule_tick()
    projects = ProjectRegistry.list()

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:snapshots, snapshots_by_project(projects))}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("select_project", %{"project" => name}, socket) do
    {:noreply, push_patch(socket, to: "/harness/deps/#{name}")}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <strong>Dependency freshness</strong>
      <span class="count">{length(@projects)} projects</span>
      <a href="/harness">← All runs</a>
    </div>

    <p :if={@projects == []}>No projects registered.</p>

    <form :if={@projects != []} id="dep-freshness-form">
      <label for="dep-freshness-select">Project</label>
      <select
        id="dep-freshness-select"
        name="project"
        phx-change="select_project"
        value={@selected_project}
      >
        <option
          :for={project <- @projects}
          value={project.name}
          selected={project.name == @selected_project}
        >
          {project.name}
        </option>
      </select>
    </form>

    <section :if={@projects != []} id="dep-freshness-panel">
      <.project_panel
        project={selected_project(@projects, @selected_project)}
        snapshot={Map.get(@snapshots, @selected_project)}
      />
    </section>
    """
  end

  attr(:project, Project, required: true)
  attr(:snapshot, Snapshot, default: nil)

  @spec project_panel(map()) :: Rendered.t()
  defp project_panel(%{snapshot: nil} = assigns) do
    ~H"""
    <div class="empty-state" id="dep-freshness-empty">
      <strong>No freshness facts yet</strong>
      <p>
        {@project.name} has not been scanned. The cron dep-freshness poller records raw
        `mix hex.outdated` rows when it next runs.
      </p>
    </div>
    """
  end

  defp project_panel(assigns) do
    ~H"""
    <p class="count" id="dep-freshness-summary">
      {@snapshot.outdated_count} outdated · last checked {format_checked_at(@snapshot.checked_at)} · provider {@snapshot.language}
    </p>

    <table id="dep-freshness-rows">
      <thead>
        <tr>
          <th>Dependency</th>
          <th>Current</th>
          <th>Latest</th>
          <th>Constraint allowed</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @snapshot.rows} class={row_class(row)}>
          <td><code>{row.name}</code></td>
          <td><code>{row.current_version}</code></td>
          <td><code>{row.latest_version}</code></td>
          <td>{constraint_allowed_label(row.constraint_allowed)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :deps_tick, @tick_interval_ms)

  @spec snapshots_by_project([Project.t()]) :: %{String.t() => Snapshot.t()}
  defp snapshots_by_project(projects) do
    case DepFreshness.list_snapshots() do
      {:ok, snapshots} ->
        snapshots
        |> Map.new(&{&1.project_name, &1})
        |> Map.take(Enum.map(projects, & &1.name))

      {:error, _reason} ->
        %{}
    end
  end

  @spec default_project_name([Project.t()]) :: String.t()
  defp default_project_name([%Project{name: name} | _rest]), do: name
  defp default_project_name([]), do: ""

  @spec selected_project([Project.t()], String.t()) :: Project.t() | nil
  defp selected_project(projects, name) do
    Enum.find(projects, &(&1.name == name)) || List.first(projects)
  end

  @spec format_checked_at(DateTime.t()) :: String.t()
  defp format_checked_at(%DateTime{} = checked_at) do
    Calendar.strftime(checked_at, "%Y-%m-%d %H:%M:%S UTC")
  end

  @spec row_class(Row.t()) :: String.t()
  defp row_class(%Row{} = row), do: if(Row.outdated?(row), do: "dep-outdated", else: "")

  @spec constraint_allowed_label(boolean()) :: String.t()
  defp constraint_allowed_label(true), do: "yes"
  defp constraint_allowed_label(false), do: "no"
end
