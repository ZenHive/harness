defmodule Harness.Dashboard.RoadmapLive do
  @moduledoc """
  Per-project roadmap rollup LiveView (`/harness/roadmap`).

  Extracted from the runs dashboard (`Harness.Dashboard.Live`) so the *planning*
  surface — how much work is open vs done per project, and how many tasks the
  lander has landed — has its own navbar destination instead of sharing scroll
  with the operational run tables.

  ## Cold-path, ticked

  The rollup is one `rmap list` per registered project (`RoadmapSummary`), which
  has no PubSub source — landing is minutes-paced — so a slow `:roadmap_tick`
  re-reads it. Registered projects (`ProjectRegistry.list/0`) are in-memory and
  refreshed on the same tick. No run streams, no store scan.

  The runs dashboard still computes its own `@roadmap` assign: the summaries are
  load-bearing there for the run tables' landed/blocked logic. This view renders
  the same data on its own page; it does not remove it from the index.

  A richer planning surface (next task, dependency waves, blocked reasons) is a
  tracked follow-up — this view is the moved 4-column rollup only.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.RoadmapSummary
  alias Harness.ProjectRegistry

  # Mirrors the runs dashboard's roadmap tick — landing is minutes-paced, so a
  # 30s re-read keeps the open/done/landed counts fresh without a PubSub source.
  @roadmap_tick_interval_ms 30_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_roadmap_tick()

    projects = ProjectRegistry.list()

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:roadmap, RoadmapSummary.for_projects(projects))}
  end

  @impl Phoenix.LiveView
  def handle_info(:roadmap_tick, socket) do
    schedule_roadmap_tick()
    projects = ProjectRegistry.list()

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:roadmap, RoadmapSummary.for_projects(projects))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

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
        <tr :for={row <- roadmap_rows(@projects, @roadmap)}>
          <td>{row.name}</td>
          <td>{row.open}</td>
          <td>{row.done}</td>
          <td>{row.total}</td>
          <td>{row.landed}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  # Flattens the projects + summaries assigns into render-ready rows so the
  # template reads one precomputed value per cell instead of re-resolving the
  # summary four times. (Moved from `Harness.Dashboard.Live`.)
  @spec roadmap_rows([map()], RoadmapSummary.summaries()) :: [map()]
  defp roadmap_rows(projects, summaries) do
    Enum.map(projects, fn project ->
      summary = RoadmapSummary.summary_for(summaries, project.name)

      %{
        name: project.name,
        open: summary.open,
        done: summary.done,
        total: summary.total,
        landed: map_size(summary.landed)
      }
    end)
  end
end
