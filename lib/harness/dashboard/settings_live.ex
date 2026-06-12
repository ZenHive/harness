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

  Hosts the per-project **Landing** card over `Harness.Landing.Settings`: the
  runtime-flippable `manual` / `auto-land` + target-branch override that arms
  autonomous merge, and a **Dispatch now** button that fires an immediate
  roadmap poll instead of waiting for the cron tick. Transient operator feedback
  rides a `:notice` assign rendered by `Harness.Dashboard.Components.operator_flash/1`.

  Designed as the home for further operator config (the Task 127 config
  inspector slots in here as a sibling card).
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentRegistry
  alias Harness.Config
  alias Harness.Cron.RoadmapPoller
  alias Harness.Cron.Settings
  alias Harness.Dashboard.Components
  alias Harness.Dashboard.ConfigInspector
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ModelAvailability
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  require Logger

  @meta_tick_interval_ms 5_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_meta_tick()
    {:ok, socket |> assign(:notice, nil) |> refresh()}
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

  def handle_event("set_schedule", %{"preset" => preset}, socket) do
    notice =
      case Settings.set_schedule(preset, "dashboard") do
        :ok -> {:ok, "Schedule updated — applies on the next restart."}
        {:error, :invalid_preset} -> {:error, "Unknown schedule preset."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("toggle_agent", %{"name" => name}, socket) do
    case agent_atom(name) do
      {:ok, agent} -> AgentSettings.set_enabled(agent, not AgentSettings.enabled?(agent), "dashboard")
      :error -> :noop
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("toggle_reviewer_eligible", %{"name" => name}, socket) do
    case agent_atom(name) do
      {:ok, agent} ->
        AgentSettings.set_reviewer_eligible(agent, not AgentSettings.reviewer_eligible?(agent), "dashboard")

      :error ->
        :noop
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("set_landing", %{"name" => name, "landing_policy" => policy, "target_branch" => branch}, socket) do
    notice =
      case LandingSettings.set(name, policy_atom(policy), branch, "dashboard") do
        :ok -> {:ok, "Landing updated for #{name}."}
        {:error, :target_branch_required} -> {:error, "Auto-land needs a target branch — none was given."}
        {:error, :invalid_policy} -> {:error, "Unknown landing policy."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("set_project_reviewer", %{"name" => name, "reviewer" => reviewer}, socket) do
    notice =
      case reviewer_atom(reviewer) do
        {:ok, pin} ->
          LandingSettings.set_reviewer(name, pin, "dashboard")
          {:ok, "Reviewer updated for #{name}."}

        :error ->
          {:error, "Unknown reviewer."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("set_config", %{"key" => id, "value" => raw}, socket) do
    notice =
      case resolve_config_edit(id, raw) do
        {:ok, entry, value} -> persist_config(entry, value)
        :error -> {:error, "Unknown or invalid config value."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("add_catalog_model", %{"agent" => agent, "model_id" => model_id}, socket) do
    notice =
      case ModelAvailability.add_catalog_model(agent, model_id) do
        :ok -> {:ok, "Added #{String.trim(model_id)} to #{agent}."}
        {:error, :empty_model} -> {:error, "Model id is required."}
        {:error, _reason} -> {:error, "Unknown model catalog agent."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("remove_catalog_model", %{"agent" => agent, "model_id" => model_id}, socket) do
    notice =
      case ModelAvailability.remove_catalog_model(agent, model_id) do
        :ok -> {:ok, "Removed #{model_id} from #{agent}."}
        {:error, _reason} -> {:error, "Unknown model catalog agent."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("refresh_catalog", %{"agent" => agent}, socket) do
    notice =
      case ModelAvailability.refresh_catalog(agent) do
        {:ok, _models} -> {:ok, "Refreshed #{agent} models."}
        {:error, :catalog_unavailable} -> {:error, "No CLI catalog available for #{agent}."}
        {:error, _reason} -> {:error, "Unknown model catalog agent."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("set_default_agent", %{"agent" => raw}, socket) do
    notice =
      case dispatch_agent_atom(raw) do
        {:ok, agent} -> persist_default_agent(agent)
        :error -> {:error, "Unknown dispatch agent."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("dispatch_now", _params, socket) do
    {:noreply, assign(socket, :notice, dispatch_now())}
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

      <Components.operator_flash notice={@notice} include_persistent={false} />

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
        <div class="setting-schedule">
          <form id="cron-schedule-form" phx-change="set_schedule">
            <label for="cron-preset">Poll cadence</label>
            <select id="cron-preset" name="preset">
              <option
                :for={{key, label, _crontab} <- @autonomy.presets}
                value={key}
                selected={key == @autonomy.active_preset}
              >
                {label}
              </option>
            </select>
          </form>
          <span class="setting-hint">
            The cron schedule is fixed at boot — a change applies on the next restart.
          </span>
        </div>
        <div class="setting-actions">
          <button
            type="button"
            class="btn-dispatch"
            phx-click="dispatch_now"
            data-confirm="Dispatch a roadmap poll right now?"
          >
            Dispatch now
          </button>
          <span class="setting-hint">
            Fire a poll immediately instead of waiting for the next cron tick.
          </span>
        </div>
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
          Two independent axes per agent. <strong>Enabled</strong> takes it in or out of
          dispatch rotation (<code>AgentRegistry.select/2</code> skips a disabled agent, so no
          run, batch, or cron tick chooses it). <strong>Reviewer</strong> governs whether it can
          be picked as the cross-family review gate — an agent can implement yet be ineligible
          to review (Pi is ineligible by default). Both choices survive a restart; distinct from a
          transient quota pause, which clears on its own.
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
              <span class="pill" data-state={if agent.reviewer_eligible, do: "on", else: "off"}>
                reviewer {if agent.reviewer_eligible, do: "eligible", else: "ineligible"}
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
            <div class="agent-controls">
              <div class="agent-control">
                <span class="agent-control-caption">enabled</span>
                <.toggle
                  on={agent.enabled}
                  event="toggle_agent"
                  value={agent.name}
                  label={"Dispatch for #{agent.label}"}
                />
              </div>
              <div class="agent-control">
                <span class="agent-control-caption">reviewer</span>
                <.toggle
                  on={agent.reviewer_eligible}
                  event="toggle_reviewer_eligible"
                  value={agent.name}
                  label={"Reviewer eligibility for #{agent.label}"}
                />
              </div>
            </div>
          </li>
        </ul>
      </section>

      <Components.landing_card projects={@landing} />

      <section class="setting-card">
        <h2 class="setting-section-title">Project reviewers</h2>
        <p class="setting-desc">
          Optional per-project reviewer pin. <strong>auto</strong>
          keeps the cross-family rejection-rate ordering; a pin still has to be
          cross-family, reviewer-eligible, and dispatchable when the run reaches the gate.
        </p>
        <ul class="project-list">
          <li :for={project <- @reviewers.projects} class="project-row">
            <form
              id={"reviewer-form-#{project.name}"}
              class="reviewer-form"
              phx-submit="set_project_reviewer"
            >
              <input type="hidden" name="name" value={project.name} />
              <div class="project-id">
                <span class="project-name">{project.label}</span>
                <span class="pill" data-state={if project.reviewer == nil, do: "off", else: "on"}>
                  reviewer {project.reviewer_label}
                </span>
              </div>
              <select name="reviewer" aria-label={"Reviewer for #{project.label}"}>
                <option value="" selected={project.reviewer == nil}>auto</option>
                <option
                  :for={option <- @reviewers.options}
                  value={option.name}
                  selected={project.reviewer == option.agent}
                >
                  {option.label}
                </option>
              </select>
              <button type="submit" class="btn-save">Save</button>
            </form>
          </li>
          <li :if={@reviewers.projects == []} class="project-empty">No projects registered.</li>
        </ul>
      </section>

      <section class="setting-card">
        <h2 class="setting-section-title">Dispatch default</h2>
        <p class="setting-desc">
          The implementer agent an <strong>unassigned</strong> task routes to when capability
          scores have no data yet (the <code>recommend</code> no-data fallback). Defaults to a
          cheap agent so unassigned work doesn't silently spend Claude tokens — Claude stays
          available on the separate <strong>reviewer</strong> axis above.
        </p>
        <form id="dispatch-default-form" class="reviewer-form" phx-submit="set_default_agent">
          <div class="project-id">
            <span class="project-name">Unassigned → implementer</span>
            <span class="pill" data-state="on">{@dispatch.current}</span>
          </div>
          <select name="agent" aria-label="Default dispatch agent">
            <option
              :for={agent <- @dispatch.agents}
              value={to_string(agent)}
              selected={agent == @dispatch.current}
            >
              {agent}
            </option>
          </select>
          <button type="submit" class="btn-save">Save</button>
        </form>
      </section>

      <section class="setting-card">
        <h2>Agent models</h2>
        <p class="setting-desc">
          Per-agent implementer model. Blank falls back to the agent's own default.
          A task's <code>model</code> pin overrides this value.
        </p>
        <form
          :for={model <- @agent_models}
          id={"agent-model-#{model.id}"}
          class="agent-model-form"
          phx-submit="set_config"
        >
          <div class="project-id">
            <span class="project-name">{model.label}</span>
          </div>
          <.model_field model={model} blank_label="agent default" />
          <button type="submit" class="btn-save">Save</button>
        </form>
      </section>

      <section class="setting-card">
        <h2>Reviewer models</h2>
        <p class="setting-desc">
          Per-agent reviewer model override. Blank inherits the agent default above; if both are
          blank, the reviewer uses the agent CLI's own default. Model ids churn — verify against
          the agent's <code>--list-models</code> before setting.
        </p>
        <form
          :for={model <- @reviewer_models}
          id={"reviewer-model-#{model.id}"}
          class="reviewer-form"
          phx-submit="set_config"
        >
          <div class="project-id">
            <span class="project-name">{model.label}</span>
          </div>
          <.model_field model={model} blank_label="inherit" />
          <button type="submit" class="btn-save">Save</button>
        </form>
      </section>

      <section class="setting-card">
        <h2>Model catalog</h2>
        <p class="setting-desc">
          Operator-editable model ids for dropdowns. Refresh merges the agent CLI list when available.
        </p>
        <ul class="project-list">
          <li :for={catalog <- @model_catalogs} class="project-row">
            <div class="project-id">
              <span class="project-name">{catalog.label}</span>
              <span class="pill" data-state={if catalog.models == [], do: "off", else: "on"}>
                {length(catalog.models)} models
              </span>
            </div>
            <div class="agent-controls">
              <form
                id={"model-catalog-add-#{catalog.name}"}
                class="agent-model-form"
                phx-submit="add_catalog_model"
              >
                <input type="hidden" name="agent" value={catalog.name} />
                <input
                  type="text"
                  name="model_id"
                  placeholder="model id"
                  aria-label={"Add #{catalog.label} model"}
                />
                <button type="submit" class="btn-save">Add</button>
              </form>
              <form
                :if={catalog.refreshable}
                id={"model-catalog-refresh-#{catalog.name}"}
                class="reviewer-form"
                phx-submit="refresh_catalog"
              >
                <input type="hidden" name="agent" value={catalog.name} />
                <button type="submit" class="btn-save">Refresh from CLI</button>
              </form>
            </div>
            <div class="agent-controls">
              <form
                :for={model <- catalog.models}
                id={"model-catalog-remove-#{catalog.name}-#{model.dom_id}"}
                class="reviewer-form"
                phx-submit="remove_catalog_model"
              >
                <input type="hidden" name="agent" value={catalog.name} />
                <input type="hidden" name="model_id" value={model.id} />
                <span class="pill" data-state="on">{model.label}</span>
                <button type="submit" class="btn-save">Remove</button>
              </form>
            </div>
          </li>
        </ul>
      </section>

      <Components.config_form entries={@config_edit} />

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
    ></button>
    """
  end

  attr(:model, :map, required: true)
  attr(:blank_label, :string, required: true)

  # The model-pin control: a `<select>` sourced from the agent's resolved catalog
  # (`ModelAvailability.list_available/1`) when one is available, falling back to a
  # free-text input when the agent has no catalog (ids churn, so text stays valid).
  # Both submit `name="value"` so the shared `set_config` handler is unchanged.
  @spec model_field(map()) :: Rendered.t()
  defp model_field(assigns) do
    ~H"""
    <input type="hidden" name="key" value={@model.id} />
    <select :if={@model.options != :none} name="value" aria-label={"#{@model.label} model"}>
      <option value="" selected={@model.input_value == ""}>{@blank_label}</option>
      <option
        :for={opt <- @model.options}
        value={opt.value}
        selected={opt.value == @model.input_value}
      >
        {opt.label}
      </option>
    </select>
    <input
      :if={@model.options == :none}
      type="text"
      name="value"
      value={@model.input_value}
      placeholder={@model.placeholder}
      aria-label={"#{@model.label} model"}
    />
    """
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket) do
    projects = ProjectRegistry.list()

    socket
    |> assign(:autonomy, autonomy_state(projects))
    |> assign(:agents, agents_state())
    |> assign(:landing, landing_state(projects))
    |> assign(:reviewers, reviewer_state(projects))
    |> assign(:config, ConfigInspector.resolve())
    |> assign(:config_edit, config_edit_state())
    |> assign(:dispatch, dispatch_state())
    |> assign(:agent_models, agent_models_state())
    |> assign(:reviewer_models, reviewer_models_state())
    |> assign(:model_catalogs, model_catalogs_state())
  end

  # The dispatch-default view-model: the configured no-data fallback agent plus
  # the closed option set the `<select>` renders. `:agent`-typed config is steered
  # by this dedicated card, so it never reaches the number-input `config_form`.
  @spec dispatch_state() :: %{current: atom(), agents: [atom()]}
  defp dispatch_state do
    %{current: Config.get({:dispatch, :default_agent}), agents: Config.dispatch_agents()}
  end

  # The editable-config view-model: the `ui_editable?` schema subset, each row
  # carrying its current resolved value as the input default and a stable string
  # `id` so `set_config` resolves the edit back to a schema entry without
  # `String.to_atom` on request input.
  @spec config_edit_state() :: [map()]
  defp config_edit_state do
    Config.editable_entries()
    |> Enum.reject(&(&1.type in [:agent, :string]))
    |> Enum.map(fn entry ->
      %{
        id: config_id(entry.key),
        label: entry.label,
        unit: config_unit(entry.type),
        input_value: config_input_value(Config.get(entry.key)),
        placeholder: config_placeholder(entry),
        restart_required?: entry.restart_required?
      }
    end)
  end

  # A CSS-id-safe stable encoding of a schema key (no `:`/`.` — those break the
  # form's `id` as a selector). Round-trips via the editable-entry lookup in
  # `resolve_config_edit/2`, so the exact string only has to be stable, not parsed.
  @spec config_id(Config.Entry.key()) :: String.t()
  defp config_id({ns, sub}), do: "#{ns}__#{sub}"
  defp config_id(flat) when is_atom(flat), do: Atom.to_string(flat)

  @spec config_unit(Config.Entry.value_type()) :: String.t()
  defp config_unit(:duration_ms), do: "ms"
  defp config_unit(_type), do: ""

  @spec config_input_value(term()) :: String.t()
  defp config_input_value(nil), do: ""
  defp config_input_value(value) when is_integer(value), do: Integer.to_string(value)
  defp config_input_value(value) when is_binary(value), do: value

  # The Agent-models card view-model: one text-input row per shared implementer
  # `{:agent_model, agent}` entry. Reuses the `set_config` event + stable
  # `config_id` round-trip as the number card, so no new event handler.
  @spec agent_models_state() :: [map()]
  defp agent_models_state do
    Config.editable_entries()
    |> Enum.filter(&match?({:agent_model, _}, &1.key))
    |> Enum.map(fn entry ->
      {:agent_model, agent} = entry.key
      value = config_input_value(Config.get(entry.key))

      %{
        id: config_id(entry.key),
        label: entry.label,
        input_value: value,
        placeholder: "agent default",
        options: model_options(agent, value)
      }
    end)
  end

  @spec reviewer_models_state() :: [map()]
  defp reviewer_models_state do
    Config.editable_entries()
    |> Enum.filter(&match?({:reviewer_model, _}, &1.key))
    |> Enum.map(fn entry ->
      {:reviewer_model, agent} = entry.key
      value = config_input_value(Config.get(entry.key))

      %{
        id: config_id(entry.key),
        label: entry.label,
        input_value: value,
        placeholder: config_input_value(Config.agent_model(agent)),
        options: model_options(agent, value)
      }
    end)
  end

  # The dropdown option set for an agent's model pin: the agent's resolved catalog
  # (probed CLI list / operator static list) mapped to `{value, label}`, with the
  # currently-pinned value appended when it isn't in the catalog so an out-of-band
  # pin survives a re-render. `:none` when the agent has no catalog — `model_field/1`
  # then renders a free-text input instead of a locked dropdown.
  @spec model_options(atom(), String.t()) :: [%{value: String.t(), label: String.t()}] | :none
  defp model_options(agent, current) do
    case ModelAvailability.list_available(agent) do
      entries when is_list(entries) and entries != [] -> catalog_options(entries, current)
      _unavailable_or_empty -> :none
    end
  end

  @spec model_catalogs_state() :: [map()]
  defp model_catalogs_state do
    Enum.map(Config.dispatch_agents(), fn agent ->
      models = catalog_models(agent)

      %{
        name: Atom.to_string(agent),
        label: agent_label(agent),
        refreshable: ModelAvailability.probeable?(agent),
        models: models
      }
    end)
  end

  @spec catalog_models(atom()) :: [map()]
  defp catalog_models(agent) do
    case ModelAvailability.catalog(agent) do
      {:ok, models} -> Enum.map(models, &catalog_model(&1))
      {:error, :catalog_unavailable} -> []
    end
  end

  @spec catalog_model(map()) :: map()
  defp catalog_model(%{id: id} = model) do
    %{id: id, label: option_label(model), dom_id: catalog_model_dom_id(id)}
  end

  @spec catalog_model_dom_id(String.t()) :: String.t()
  defp catalog_model_dom_id(id), do: String.replace(id, ~r/[^a-zA-Z0-9_-]/, "_")

  @spec catalog_options([map()], String.t()) :: [%{value: String.t(), label: String.t()}]
  defp catalog_options(entries, current) do
    options = Enum.map(entries, &%{value: &1.id, label: option_label(&1)})

    if current == "" or Enum.any?(options, &(&1.value == current)) do
      options
    else
      options ++ [%{value: current, label: "#{current} (set)"}]
    end
  end

  # A catalog entry renders as its id, with the human label appended when distinct —
  # the id is what gets saved, the label is the recognizability hint.
  @spec option_label(map()) :: String.t()
  defp option_label(%{id: id, label: label}) when is_binary(label) and label != "" and label != id, do: "#{id} — #{label}"

  defp option_label(%{id: id}), do: id

  @spec config_placeholder(Config.Entry.t()) :: String.t()
  defp config_placeholder(%{type: :duration_ms, default: nil}), do: "unbounded"
  defp config_placeholder(%{default: default}), do: config_input_value(default)

  # Resolves a submitted form `id` back to its schema entry (never String.to_atom
  # on request input) and parses the raw string per the entry's type. An empty
  # input on a nullable duration is nil (unbounded); any other unparseable value
  # is `:error`, surfaced as a notice.
  @spec resolve_config_edit(String.t(), String.t()) :: {:ok, Config.Entry.t(), term()} | :error
  defp resolve_config_edit(id, raw) do
    case Enum.find(Config.editable_entries(), &(config_id(&1.key) == id)) do
      %{type: type} = entry ->
        case parse_config_value(String.trim(raw), type) do
          {:ok, value} -> {:ok, entry, value}
          :error -> :error
        end

      nil ->
        :error
    end
  end

  @spec parse_config_value(String.t(), Config.Entry.value_type()) :: {:ok, term()} | :error
  defp parse_config_value("", :duration_ms), do: {:ok, nil}

  defp parse_config_value(raw, type) when type in [:duration_ms, :integer] do
    case Integer.parse(raw) do
      {value, ""} -> {:ok, value}
      _unparseable -> :error
    end
  end

  # A free-text model pin: blank clears it (falls back to the agent CLI default),
  # any other string persists verbatim — model ids are unvalidated (they churn).
  defp parse_config_value("", :string), do: {:ok, nil}
  defp parse_config_value(raw, :string), do: {:ok, raw}

  defp parse_config_value(_raw, _type), do: :error

  @spec persist_config(Config.Entry.t(), term()) :: {:ok | :error, String.t()}
  defp persist_config(entry, value) do
    case Config.put(entry.key, value, "dashboard") do
      :ok -> {:ok, config_saved_notice(entry)}
      {:error, _reason} -> {:error, "Could not save #{entry.label}."}
    end
  end

  @spec config_saved_notice(Config.Entry.t()) :: String.t()
  defp config_saved_notice(%{restart_required?: true, label: label}),
    do: "#{label} saved — applies on the next node restart."

  defp config_saved_notice(%{label: label}), do: "#{label} saved."

  # The per-project landing view-model: the *effective* policy (project default
  # overlaid with the operator's persisted override) rendered as the Landing card.
  @spec landing_state([Project.t()]) :: [map()]
  defp landing_state(projects) do
    Enum.map(projects, fn project ->
      %{landing_policy: policy, target_branch: branch} = LandingSettings.effective(project)
      %{name: project.name, label: project.name, auto?: policy == :auto, target_branch: branch}
    end)
  end

  @spec reviewer_state([Project.t()]) :: map()
  defp reviewer_state(projects) do
    options = reviewer_options()

    rows =
      Enum.map(projects, fn project ->
        %{reviewer: reviewer} = LandingSettings.effective(project)

        %{
          name: project.name,
          label: project.name,
          reviewer: reviewer,
          reviewer_label: reviewer_label(reviewer)
        }
      end)

    %{projects: rows, options: options}
  end

  # Maps the select's string value to a policy atom without `String.to_atom` on
  # request input — an unknown value becomes `:invalid`, which `set/4` rejects.
  @spec policy_atom(String.t()) :: :auto | :manual | :invalid
  defp policy_atom("auto"), do: :auto
  defp policy_atom("manual"), do: :manual
  defp policy_atom(_other), do: :invalid

  # Fires a roadmap poll immediately instead of waiting for the cron tick. Honors
  # the master kill-switch — a poll with master off would be a no-op, so we say so
  # rather than enqueue a tick that dispatches nothing.
  @spec dispatch_now() :: {:ok | :error, String.t()}
  defp dispatch_now do
    if Settings.master_enabled?() do
      enqueue_poll()
    else
      {:error, "Master autonomy is off — enable it before dispatching."}
    end
  end

  @spec enqueue_poll() :: {:ok | :error, String.t()}
  defp enqueue_poll do
    case %{} |> RoadmapPoller.new() |> HarnessOban.insert() do
      {:ok, _job} ->
        {:ok, "Poll dispatched — watch the dashboard for new runs."}

      {:error, reason} ->
        Logger.warning("harness dashboard: dispatch-now enqueue failed: #{inspect(reason)}")
        {:error, "Could not enqueue a poll."}
    end
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
        label: agent_label(agent),
        enabled: AgentSettings.enabled?(agent),
        reviewer_eligible: AgentSettings.reviewer_eligible?(agent),
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

  @spec reviewer_atom(String.t()) :: {:ok, atom() | nil} | :error
  defp reviewer_atom(""), do: {:ok, nil}
  defp reviewer_atom(name), do: agent_atom(name)

  # Maps the dispatch-default select's string value to an agent atom against the
  # closed `Config.dispatch_agents/0` set (never String.to_atom on request input).
  # Unlike `agent_atom/1`, the source is the validation set, not the installed
  # registry — the default may name an adapter not currently registered.
  @spec dispatch_agent_atom(String.t()) :: {:ok, atom()} | :error
  defp dispatch_agent_atom(name) do
    case Enum.find(Config.dispatch_agents(), &(Atom.to_string(&1) == name)) do
      nil -> :error
      agent -> {:ok, agent}
    end
  end

  @spec persist_default_agent(atom()) :: {:ok | :error, String.t()}
  defp persist_default_agent(agent) do
    case Config.put({:dispatch, :default_agent}, agent, "dashboard") do
      :ok -> {:ok, "Default dispatch agent set to #{agent}."}
      {:error, _reason} -> {:error, "Could not save default dispatch agent."}
    end
  end

  @spec reviewer_options() :: [map()]
  defp reviewer_options do
    Enum.map(AgentRegistry.agents(), fn {agent, _module} ->
      name = Atom.to_string(agent)
      %{agent: agent, name: name, label: agent_label(agent)}
    end)
  end

  @spec reviewer_label(atom() | nil) :: String.t()
  defp reviewer_label(nil), do: "auto"
  defp reviewer_label(reviewer), do: agent_label(reviewer)

  @spec agent_label(atom()) :: String.t()
  defp agent_label(agent), do: agent |> Atom.to_string() |> String.capitalize()

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
      any_effective?: Enum.any?(rows, & &1.effective),
      presets: Settings.schedule_presets(),
      active_preset: Settings.active_preset()
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
