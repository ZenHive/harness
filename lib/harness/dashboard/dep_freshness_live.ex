defmodule Harness.Dashboard.DepFreshnessLive do
  @moduledoc """
  Per-project dependency freshness and tooling-baseline panel (`/harness/deps`).

  Displays raw provider facts — dependency rows, baseline drift, overrides, and
  advisory-only operator-machine surface. Harness counts and renders only.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.ProjectSelection
  alias Harness.DepFreshness
  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.Dispatch
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ToolingBaseline.Item, as: ConformanceItem
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
  def handle_params(params, _uri, socket) do
    ProjectSelection.handle_params(params, socket)
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

  def handle_event("update_deps", %{"project" => name}, socket) do
    {:noreply, dispatch_update_deps(socket, name)}
  end

  def handle_event("tooling_baseline", %{"project" => name}, socket) do
    {:noreply, dispatch_tooling_baseline(socket, name)}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <strong>Dependencies &amp; tooling</strong>
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
        project={ProjectSelection.selected_project(@projects, @selected_project)}
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
        language-provider rows when it next runs.
      </p>
    </div>
    """
  end

  defp project_panel(assigns) do
    ~H"""
    <p class="count" id="dep-freshness-summary">
      {@snapshot.outdated_count} outdated · last checked {ProjectSelection.format_checked_at(
        @snapshot.checked_at
      )} · provider {@snapshot.language}
    </p>

    <button
      id="dep-update-button"
      type="button"
      phx-click="update_deps"
      phx-value-project={@project.name}
      disabled={@snapshot.outdated_count == 0}
    >
      Update deps
    </button>

    <h3>Dependency freshness</h3>

    <table id="dep-freshness-rows">
      <thead>
        <tr>
          <th>Dependency</th>
          <th>Current</th>
          <th>Latest</th>
          <th>Constraint allowed</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @snapshot.rows} class={row_class(row)}>
          <td><code>{row.name}</code></td>
          <td><code>{row.current_version}</code></td>
          <td><code>{row.latest_version}</code></td>
          <td>{constraint_allowed_label(row.constraint_allowed)}</td>
          <td>{row_status_label(row)}</td>
        </tr>
      </tbody>
    </table>

    <.conformance_panel
      :if={@snapshot.conformance}
      project={@project}
      conformance={@snapshot.conformance}
    />
    """
  end

  attr(:project, Project, required: true)
  attr(:conformance, :map, required: true)

  @spec conformance_panel(map()) :: Rendered.t()
  defp conformance_panel(assigns) do
    ~H"""
    <section id="tooling-baseline-panel">
      <h3>Tooling baseline</h3>
      <p class="count" id="tooling-baseline-summary">
        {@conformance.drift_count} drift · last checked {ProjectSelection.format_checked_at(
          @conformance.checked_at
        )}
      </p>

      <button
        id="tooling-baseline-button"
        type="button"
        phx-click="tooling_baseline"
        phx-value-project={@project.name}
        disabled={@conformance.drift_count == 0}
      >
        Bring to baseline
      </button>

      <table id="tooling-baseline-items">
        <thead>
          <tr>
            <th>Item</th>
            <th>Category</th>
            <th>Status</th>
            <th>Override reason</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={item <- @conformance.items} class={conformance_row_class(item)}>
            <td><code>{item.label}</code></td>
            <td>{conformance_category_label(item.category)}</td>
            <td>{conformance_status_label(item.status)}</td>
            <td>{item.override_reason || "—"}</td>
          </tr>
        </tbody>
      </table>

      <h4>Advisory (not enforced)</h4>
      <ul id="tooling-baseline-advisory">
        <li :for={entry <- @conformance.advisory}>
          <strong>{entry.label}</strong> — {entry.description}
        </li>
      </ul>
    </section>
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

  @spec dispatch_update_deps(Socket.t(), String.t()) :: Socket.t()
  defp dispatch_update_deps(%Socket{} = socket, project_name) when is_binary(project_name) do
    case Dispatch.update_deps(project_name) do
      {:ok, %{tasks: tasks}} ->
        put_flash(socket, :info, "Dispatched #{length(tasks)} dependency bump run(s).")

      {:error, reason} ->
        put_flash(socket, :error, "Dependency bump dispatch failed: #{inspect(reason)}")
    end
  end

  @spec dispatch_tooling_baseline(Socket.t(), String.t()) :: Socket.t()
  defp dispatch_tooling_baseline(%Socket{} = socket, project_name) when is_binary(project_name) do
    case Dispatch.tooling_baseline(project_name) do
      {:ok, %{tasks: tasks}} ->
        put_flash(socket, :info, "Dispatched #{length(tasks)} tooling baseline run(s).")

      {:error, reason} ->
        put_flash(socket, :error, "Tooling baseline dispatch failed: #{inspect(reason)}")
    end
  end

  @spec row_class(Row.t()) :: String.t()
  defp row_class(%Row{status: :skipped}), do: "dep-skipped"
  defp row_class(%Row{} = row), do: if(Row.outdated?(row), do: "dep-outdated", else: "")

  @spec row_status_label(Row.t()) :: String.t()
  defp row_status_label(%Row{status: :skipped, reason: reason}), do: "skipped #{reason}"
  defp row_status_label(%Row{}), do: "ok"

  @spec constraint_allowed_label(boolean()) :: String.t()
  defp constraint_allowed_label(true), do: "yes"
  defp constraint_allowed_label(false), do: "no"

  @spec conformance_row_class(ConformanceItem.t()) :: String.t()
  defp conformance_row_class(%ConformanceItem{} = item) do
    case item.status do
      :missing -> "tooling-baseline-missing"
      :overridden -> "tooling-baseline-overridden"
      _other -> ""
    end
  end

  @spec conformance_category_label(ConformanceItem.category()) :: String.t()
  defp conformance_category_label(:dep), do: "dep"
  defp conformance_category_label(:alias), do: "alias"
  defp conformance_category_label(:config_file), do: "config"
  defp conformance_category_label(:provider), do: "provider"

  @spec conformance_status_label(ConformanceItem.status()) :: String.t()
  defp conformance_status_label(:present), do: "present"
  defp conformance_status_label(:missing), do: "missing"
  defp conformance_status_label(:overridden), do: "overridden"
  defp conformance_status_label(:skipped), do: "skipped"
end
