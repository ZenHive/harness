defmodule Harness.Dashboard.RoadmapLive do
  @moduledoc """
  Per-project roadmap planning LiveView (`/harness/roadmap`).

  Extracted from the runs dashboard (`Harness.Dashboard.Live`) so the *planning*
  surface has its own navbar destination instead of sharing scroll with the
  operational run tables. It shows the rollup plus a read-only drill-down for
  "what's next / what's blocked / what's dispatchable in parallel?".

  ## Cold-path, ticked

  The rollup and drill-down facts have no PubSub source — landing is
  minutes-paced — so a slow `:roadmap_tick` re-reads them. Registered projects
  (`ProjectRegistry.list/0`) are in-memory and refreshed on the same tick. Row
  expansion only toggles already-loaded facts; it never shells out from a click.

  The runs dashboard still computes its own `@roadmap` assign: the summaries are
  load-bearing there for the run tables' landed/blocked logic. This view renders
  the same data on its own page; it does not remove it from the index.

  This view counts and displays roadmap facts from `rmap`'s structured output. It
  does not compute agent recommendations or bespoke priority scores.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.RoadmapSummary
  alias Harness.ProjectRegistry
  alias Harness.Roadmap

  # Mirrors the runs dashboard's roadmap tick — landing is minutes-paced, so a
  # 30s re-read keeps the open/done/landed counts fresh without a PubSub source.
  @roadmap_tick_interval_ms 30_000
  @drilldown_timeout_ms 5_000
  @ready_fields ~w(id title dep_layer eff)

  @typep drilldown :: %{
           next_task: map() | nil,
           blocked: [map()],
           waves: [{integer(), [map()]}]
         }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_roadmap_tick()

    projects = ProjectRegistry.list()
    {roadmap, drilldowns} = roadmap_snapshot(projects)

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:roadmap, roadmap)
     |> assign(:drilldowns, drilldowns)
     |> assign(:expanded_projects, MapSet.new())}
  end

  @impl Phoenix.LiveView
  def handle_info(:roadmap_tick, socket) do
    schedule_roadmap_tick()
    projects = ProjectRegistry.list()
    {roadmap, drilldowns} = roadmap_snapshot(projects)

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:roadmap, roadmap)
     |> assign(:drilldowns, drilldowns)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("toggle_project", %{"project" => name}, socket) do
    {:noreply, update(socket, :expanded_projects, &toggle_project(&1, name))}
  end

  @spec schedule_roadmap_tick() :: reference()
  defp schedule_roadmap_tick, do: Process.send_after(self(), :roadmap_tick, @roadmap_tick_interval_ms)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <strong>Roadmap</strong>
      <span class="count">{length(@projects)} projects</span>
      <a href="/harness">← All runs</a>
    </div>

    <p :if={@projects == []}>No projects registered.</p>
    <table :if={@projects != []}>
      <thead>
        <tr>
          <th>Project</th>
          <th>Open</th>
          <th>Done</th>
          <th>Total</th>
          <th>Landed</th>
        </tr>
      </thead>
      <tbody>
        <%= for row <- roadmap_rows(@projects, @roadmap, @drilldowns) do %>
          <tr>
            <td>
              <button type="button" phx-click="toggle_project" phx-value-project={row.name}>
                {row.name}
              </button>
            </td>
            <td>{row.open}</td>
            <td>{row.done}</td>
            <td>{row.total}</td>
            <td>{row.landed}</td>
          </tr>
          <tr :if={expanded?(@expanded_projects, row.name)}>
            <td colspan="5">
              <section>
                <h2>{row.name} planning</h2>

                <div>
                  <strong>Next pending</strong>
                  <p :if={is_nil(row.next_task)}>No next pending task.</p>
                  <p :if={not is_nil(row.next_task)}>
                    {task_ref(row.next_task)} {task_title(row.next_task)}
                    <span :if={task_eff(row.next_task)}>Eff {task_eff(row.next_task)}</span>
                  </p>
                </div>

                <div>
                  <strong>Blocked ({length(row.blocked)})</strong>
                  <p :if={row.blocked == []}>No blocked tasks.</p>
                  <ul :if={row.blocked != []}>
                    <li :for={task <- row.blocked}>
                      {task_ref(task)} {task_title(task)} — {blocked_reason(task)}
                    </li>
                  </ul>
                </div>

                <div>
                  <strong>Dispatch waves</strong>
                  <p :if={row.waves == []}>No dispatchable tasks.</p>
                  <div :for={{layer, tasks} <- row.waves}>
                    <h3>Wave {layer}</h3>
                    <ul>
                      <li :for={task <- tasks}>
                        {task_ref(task)} {task_title(task)}
                        <span :if={task_eff(task)}>Eff {task_eff(task)}</span>
                      </li>
                    </ul>
                  </div>
                </div>
              </section>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  @spec roadmap_snapshot([Harness.Project.t()]) :: {RoadmapSummary.summaries(), %{optional(String.t()) => drilldown()}}
  defp roadmap_snapshot(projects) do
    {RoadmapSummary.for_projects(projects), drilldowns_for_projects(projects)}
  end

  @spec drilldowns_for_projects([Harness.Project.t()]) :: %{optional(String.t()) => drilldown()}
  defp drilldowns_for_projects(projects) do
    projects
    |> Task.async_stream(&drilldown_for_project/1, timeout: @drilldown_timeout_ms, on_timeout: :kill_task)
    |> Enum.zip(projects)
    |> Map.new(fn
      {{:ok, drilldown}, project} -> {project.name, drilldown}
      {{:exit, _reason}, project} -> {project.name, empty_drilldown()}
    end)
  end

  @spec drilldown_for_project(Harness.Project.t()) :: drilldown()
  defp drilldown_for_project(project) do
    %{
      next_task: next_task(project),
      blocked: blocked_tasks(project),
      waves: ready_waves(project)
    }
  end

  @spec next_task(Harness.Project.t()) :: map() | nil
  defp next_task(project) do
    case next_bundle(project) do
      {:ok, %{tasks: [task | _rest]}} -> task
      _other -> nil
    end
  end

  @spec blocked_tasks(Harness.Project.t()) :: [map()]
  defp blocked_tasks(project) do
    case list_blocked(project) do
      {:ok, tasks} -> tasks
      _other -> []
    end
  end

  @spec ready_waves(Harness.Project.t()) :: [{integer(), [map()]}]
  defp ready_waves(project) do
    case ready_tasks(project) do
      {:ok, tasks} -> group_by_wave(tasks)
      _other -> []
    end
  end

  @spec next_bundle(Harness.Project.t()) :: {:ok, %{bundle: map() | nil, tasks: [map()]}} | {:error, term()}
  defp next_bundle(project) do
    case Application.get_env(:harness, :roadmap_next_bundle) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.next_bundle(project.name)
    end
  end

  @spec list_blocked(Harness.Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp list_blocked(project) do
    case Application.get_env(:harness, :roadmap_list) do
      fun when is_function(fun, 1) -> with {:ok, tasks} <- fun.(project), do: {:ok, Enum.filter(tasks, &blocked_task?/1)}
      _other -> Roadmap.list(project.name, "blocked")
    end
  end

  @spec ready_tasks(Harness.Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp ready_tasks(project) do
    case Application.get_env(:harness, :roadmap_ready) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.ready(project: project, fields: @ready_fields)
    end
  end

  @spec group_by_wave([map()]) :: [{integer(), [map()]}]
  defp group_by_wave(tasks) do
    tasks
    |> Enum.group_by(&dep_layer/1)
    |> Enum.sort_by(fn {layer, _tasks} -> layer end)
  end

  @spec dep_layer(map()) :: integer()
  defp dep_layer(%{"dep_layer" => layer}) when is_integer(layer), do: layer
  defp dep_layer(_task), do: 0

  @spec blocked_task?(map()) :: boolean()
  defp blocked_task?(%{"status" => "blocked"}), do: true
  defp blocked_task?(_task), do: false

  @spec empty_drilldown() :: drilldown()
  defp empty_drilldown, do: %{next_task: nil, blocked: [], waves: []}

  @spec toggle_project(MapSet.t(String.t()), String.t()) :: MapSet.t(String.t())
  defp toggle_project(projects, name) do
    if MapSet.member?(projects, name), do: MapSet.delete(projects, name), else: MapSet.put(projects, name)
  end

  @spec expanded?(MapSet.t(String.t()), String.t()) :: boolean()
  defp expanded?(projects, name), do: MapSet.member?(projects, name)

  # Flattens the projects + summaries assigns into render-ready rows so the
  # template reads one precomputed value per cell instead of re-resolving the
  # summary four times. (Moved from `Harness.Dashboard.Live`.)
  @spec roadmap_rows([map()], RoadmapSummary.summaries(), %{optional(String.t()) => drilldown()}) :: [map()]
  defp roadmap_rows(projects, summaries, drilldowns) do
    Enum.map(projects, fn project ->
      summary = RoadmapSummary.summary_for(summaries, project.name)
      drilldown = Map.get(drilldowns, project.name, empty_drilldown())

      %{
        name: project.name,
        open: summary.open,
        done: summary.done,
        total: summary.total,
        landed: map_size(summary.landed),
        next_task: drilldown.next_task,
        blocked: drilldown.blocked,
        waves: drilldown.waves
      }
    end)
  end

  @spec task_ref(map()) :: String.t()
  defp task_ref(%{"id" => id}), do: "##{id}"
  defp task_ref(_task), do: "#?"

  @spec task_title(map()) :: String.t()
  defp task_title(%{"title" => title}) when is_binary(title), do: title
  defp task_title(_task), do: "Untitled task"

  @spec blocked_reason(map()) :: String.t()
  defp blocked_reason(%{"blocked_reason" => reason}) when is_binary(reason) and reason != "", do: reason
  defp blocked_reason(_task), do: "No blocked reason recorded."

  @spec task_eff(map()) :: String.t() | nil
  defp task_eff(%{"eff" => eff}) when is_float(eff) do
    eff
    |> :erlang.float_to_binary(decimals: 2)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp task_eff(%{"eff" => eff}) when is_integer(eff), do: Integer.to_string(eff)
  defp task_eff(%{"eff" => eff}) when is_binary(eff) and eff != "", do: eff
  defp task_eff(_task), do: nil
end
