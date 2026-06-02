defmodule Harness.Dashboard.SettingsLive do
  @moduledoc """
  Operator settings surface (`/harness/settings`).

  Hosts the cron-autonomy controls (Tasks 109/110): the fleet-wide master
  switch (the incident kill-switch) and a per-project autonomy toggle, over
  `Harness.Cron.Settings`. The resolved poll status comes from
  `Harness.Cron.RoadmapPoller.status/0`; effective autonomy is `master AND
  project`. A slow `:meta_tick` keeps the project list fresh against
  `ProjectRegistry` since registration has no event source.

  Also hosts the per-agent dispatch controls (Task 128): enable/disable
  toggles over `Harness.Agent.Settings`, plus installed/paused pills — the
  transient quota-unavailability signal (`AgentRegistry.list_unavailable/0`)
  renders only here, not on the run dashboard.

  Designed as the home for further operator config (the Task 127 config
  inspector slots in here as a sibling card).
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentRegistry
  alias Harness.Cron.RoadmapPoller
  alias Harness.Cron.Settings
  alias Harness.Dashboard.Components
  alias Harness.Dashboard.ConfigInspector
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @meta_tick_interval_ms 5_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_meta_tick()
    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info(:meta_tick, socket) do
    schedule_meta_tick()
    {:noreply, refresh(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("toggle_master_autonomy", _params, socket) do
    Settings.set_master(not socket.assigns.autonomy.master, "dashboard")
    {:noreply, refresh(socket)}
  end

  def handle_event("toggle_project_autonomy", %{"name" => name}, socket) do
    Settings.set_project(name, not project_flag(socket.assigns.autonomy, name), "dashboard")
    {:noreply, refresh(socket)}
  end

  def handle_event("toggle_agent", %{"name" => name}, socket) do
    case agent_atom(name) do
      {:ok, agent} -> AgentSettings.set_enabled(agent, not AgentSettings.enabled?(agent), "dashboard")
      :error -> :noop
    end

    {:noreply, refresh(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="settings">
      <header class="settings-head">
        <h1>Settings</h1>
        <p class="settings-sub">Operator controls for autonomous roadmap polling.</p>
      </header>

      <section class="setting-card setting-master" data-on={to_string(@autonomy.master)}>
        <div class="setting-master-row">
          <div>
            <h2>Cron autonomy</h2>
            <p class="setting-desc">
              Fleet-wide master switch and incident kill-switch. When on, the cron poller
              dispatches each enabled project's next pending task on its schedule — one run
              at a time. Effective autonomy is master <em>and</em> project.
            </p>
            <p class="setting-status">
              <span class="pill" data-state={master_pill(@autonomy)}>{master_pill(@autonomy)}</span>
              {autonomy_status_label(@autonomy.status)}
            </p>
          </div>
          <.toggle
            on={@autonomy.master}
            event="toggle_master_autonomy"
            confirm={master_confirm(@autonomy.master)}
            label="Master autonomy"
          />
        </div>
        <p :if={@autonomy.master and not @autonomy.any_effective?} class="setting-warn">
          Master is on but no project is enabled — nothing will dispatch. Enable a project below.
        </p>
      </section>

      <section class="setting-card">
        <h2 class="setting-section-title">Per-project autonomy</h2>
        <ul class="project-list">
          <li
            :for={project <- @autonomy.projects}
            class="project-row"
            data-effective={to_string(project.effective)}
          >
            <div class="project-id">
              <span class="project-name">{project.name}</span>
              <span class="pill" data-state={if project.effective, do: "on", else: "off"}>
                {if project.effective, do: "dispatching", else: "paused"}
              </span>
            </div>
            <.toggle
              on={project.project_on}
              event="toggle_project_autonomy"
              value={project.name}
              label={"Autonomy for #{project.name}"}
            />
          </li>
          <li :if={@autonomy.projects == []} class="project-empty">No projects registered.</li>
        </ul>
      </section>

      <section class="setting-card">
        <h2 class="setting-section-title">Agents</h2>
        <p class="setting-desc">
          Take an agent out of dispatch rotation. A disabled agent is skipped by <code>AgentRegistry.select/2</code>, so no run, batch, or cron tick will
          choose it; the choice survives a restart. Distinct from a transient quota
          pause, which clears on its own.
        </p>
        <ul class="project-list">
          <li
            :for={agent <- @agents}
            class="project-row"
            data-effective={to_string(agent.enabled)}
          >
            <div class="project-id">
              <span class="project-name">{agent.label}</span>
              <span class="pill" data-state={if agent.enabled, do: "on", else: "off"}>
                {if agent.enabled, do: "enabled", else: "disabled"}
              </span>
              <span
                :if={not agent.installed}
                class="pill"
                data-state="off"
                title="CLI binary not on PATH"
              >
                not installed
              </span>
              <span
                :if={agent.unavailable != nil}
                class="pill"
                data-state="off"
                title={"transient pause: #{inspect(agent.unavailable)} — clears on its own or restart"}
              >
                paused
              </span>
            </div>
            <.toggle
              on={agent.enabled}
              event="toggle_agent"
              value={agent.name}
              label={"Dispatch for #{agent.label}"}
            />
          </li>
        </ul>
      </section>

      <Components.config_inspector sections={@config} />
    </div>
    """
  end

  attr(:on, :boolean, required: true)
  attr(:event, :string, required: true)
  attr(:value, :string, default: nil)
  attr(:confirm, :string, default: nil)
  attr(:label, :string, required: true)

  # A `role="switch"` button styled as a track + thumb. `phx-value-name` is
  # omitted by Phoenix when `@value` is nil (the master toggle needs no value).
  @spec toggle(map()) :: Rendered.t()
  defp toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="toggle"
      role="switch"
      aria-checked={to_string(@on)}
      aria-label={@label}
      phx-click={@event}
      phx-value-name={@value}
      data-confirm={@confirm}
    >
    </button>
    """
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket) do
    socket
    |> assign(:autonomy, autonomy_state(ProjectRegistry.list()))
    |> assign(:agents, agents_state())
    |> assign(:config, ConfigInspector.resolve())
  end

  # The per-agent enable/disable view-model over the registry's agent set:
  # operator enablement (persisted), whether the CLI binary is on PATH (a
  # disabled-but-installed agent is an operator choice; an enabled-but-missing
  # one explains a `:no_available_agent` at dispatch), and the transient
  # unavailability reason (quota pause), nil when dispatchable.
  @spec agents_state() :: [map()]
  defp agents_state do
    unavailable = Map.new(AgentRegistry.list_unavailable())

    Enum.map(AgentRegistry.agents(), fn {agent, module} ->
      %{
        name: Atom.to_string(agent),
        label: String.capitalize(Atom.to_string(agent)),
        enabled: AgentSettings.enabled?(agent),
        installed: AgentRegistry.installed?(module),
        unavailable: Map.get(unavailable, module)
      }
    end)
  end

  # Resolves a phx-value agent string back to its atom, accepting only the known
  # registry keys (never String.to_atom on request input).
  @spec agent_atom(String.t()) :: {:ok, atom()} | :error
  defp agent_atom(name) do
    case Enum.find(AgentRegistry.agents(), fn {agent, _} -> Atom.to_string(agent) == name end) do
      {agent, _module} -> {:ok, agent}
      nil -> :error
    end
  end

  # Resolves the autonomy view-model: the master flag, the poller's resolved cron
  # status, and per-project (own flag, effective = master AND own) rows.
  @spec autonomy_state([Project.t()]) :: map()
  defp autonomy_state(projects) do
    master = Settings.master_enabled?()

    rows =
      Enum.map(projects, fn project ->
        project_on = Settings.project_enabled?(project)
        %{name: project.name, project_on: project_on, effective: master and project_on}
      end)

    %{
      master: master,
      status: RoadmapPoller.status(),
      projects: rows,
      any_effective?: Enum.any?(rows, & &1.effective)
    }
  end

  @spec project_flag(map(), String.t()) :: boolean()
  defp project_flag(autonomy, name) do
    Enum.any?(autonomy.projects, &(&1.name == name and &1.project_on))
  end

  # The pill word doubles as its `data-state` (drives the CSS colour): "off"
  # when master is down, "armed" when master is up but nothing dispatches yet,
  # "on" once at least one project is effective.
  @spec master_pill(map()) :: String.t()
  defp master_pill(%{master: false}), do: "off"
  defp master_pill(%{master: true, any_effective?: true}), do: "on"
  defp master_pill(%{master: true, any_effective?: false}), do: "armed"

  @spec master_confirm(boolean()) :: String.t()
  defp master_confirm(true), do: "Disable autonomy? The cron poller will stop dispatching new runs."
  defp master_confirm(false), do: "Enable autonomy? The cron poller will dispatch enabled projects on its schedule."

  @spec autonomy_status_label(RoadmapPoller.cron_status()) :: String.t()
  defp autonomy_status_label(:disabled), do: "polling disabled"
  defp autonomy_status_label({:enabled, schedule, :unknown}), do: "scheduled #{schedule}, next tick unknown"

  defp autonomy_status_label({:enabled, schedule, %DateTime{} = tick}),
    do: "scheduled #{schedule}, next #{DateTime.to_iso8601(tick)}"

  defp autonomy_status_label({:invalid, schedule, _reason}), do: "invalid schedule #{schedule}"

  @spec schedule_meta_tick() :: reference()
  defp schedule_meta_tick, do: Process.send_after(self(), :meta_tick, @meta_tick_interval_ms)
end
