defmodule Harness.Dashboard.SettingsComponents do
  @moduledoc """
  Function components for the operator settings page (`Harness.Dashboard.SettingsLive`).

  Extracted from `SettingsLive`'s `render/1` (which had grown to one ~330-line
  template owning eight `setting-card` sections inline). Each card is now a
  single-attr function component taking the view-model `SettingsLive` already
  builds (`autonomy`, `agents`, `reviewers`, …); the LiveView's render reads as
  a table of contents over these.

  Pure presentation: `attr/3` + HEEx `:if` / `:for` only, no `Phoenix.HTML.raw/1`
  on interpolated content. The cards fire `phx-click` / `phx-submit` events
  (`toggle_master_autonomy`, `set_config`, …) handled back in `SettingsLive` —
  the markup lives here, the event logic stays there. Shared form controls
  (`toggle/1`, `model_field/1`) and the autonomy presentation helpers
  (`master_pill/1`, `master_confirm/1`, `autonomy_status_label/1`) live here too,
  since nothing outside the settings cards uses them.

  The four other settings cards (`landing_card`, `project_settings_card`,
  `config_form`, `config_inspector`) remain in `Harness.Dashboard.Components` —
  they were already extracted and don't contribute to `SettingsLive`'s size.
  """

  use Phoenix.Component

  alias Harness.Cron.RoadmapPoller
  alias Phoenix.LiveView.Rendered

  attr(:autonomy, :map, required: true)

  @doc """
  The fleet-wide cron autonomy card — master switch, kill-switch, poll cadence,
  and the "Dispatch now" immediate-poll button.
  """
  @spec cron_autonomy_card(map()) :: Rendered.t()
  def cron_autonomy_card(assigns) do
    ~H"""
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
    """
  end

  attr(:autonomy, :map, required: true)

  @doc """
  Per-project autonomy toggles — each project's own enable flag plus its
  effective (master AND project) dispatching pill.
  """
  @spec project_autonomy_card(map()) :: Rendered.t()
  def project_autonomy_card(assigns) do
    ~H"""
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
    """
  end

  attr(:agents, :list, required: true)

  @doc """
  Per-agent dispatch + reviewer-eligibility toggles, with installed/paused pills.
  Two independent axes: dispatch rotation and cross-family review eligibility.
  """
  @spec agents_card(map()) :: Rendered.t()
  def agents_card(assigns) do
    ~H"""
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
    """
  end

  attr(:reviewers, :map, required: true)

  @doc """
  Optional per-project reviewer pin (auto keeps the cross-family
  rejection-rate ordering; a pin still has to be cross-family + eligible).
  """
  @spec project_reviewers_card(map()) :: Rendered.t()
  def project_reviewers_card(assigns) do
    ~H"""
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
    """
  end

  attr(:dispatch, :map, required: true)

  @doc """
  The dispatch-default card — the implementer agent an unassigned task routes to
  when capability scores have no data yet (the `recommend` no-data fallback).
  """
  @spec dispatch_default_card(map()) :: Rendered.t()
  def dispatch_default_card(assigns) do
    ~H"""
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
    """
  end

  attr(:agent_models, :list, required: true)

  @doc """
  Per-agent implementer model pins. Required for every model-capable agent —
  blank rejects the dispatch as `model_required` (no silent CLI default).
  """
  @spec agent_models_card(map()) :: Rendered.t()
  def agent_models_card(assigns) do
    ~H"""
    <section class="setting-card">
      <h2>Agent models</h2>
      <p class="setting-desc">
        Per-agent implementer model. Required for every model-capable agent — blank
        rejects the dispatch as <code>model_required</code> (no silent CLI default).
        Antigravity is exempt (its CLI has no <code>--model</code> flag).
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
    """
  end

  attr(:reviewer_models, :list, required: true)

  @doc """
  Per-agent reviewer model overrides. Blank inherits the agent default; if both
  are blank, a model-capable reviewer is rejected as `model_required`.
  """
  @spec reviewer_models_card(map()) :: Rendered.t()
  def reviewer_models_card(assigns) do
    ~H"""
    <section class="setting-card">
      <h2>Reviewer models</h2>
      <p class="setting-desc">
        Per-agent reviewer model override. Blank inherits the agent default above; if both are
        blank, the reviewer is rejected as <code>model_required</code> for model-capable agents —
        never a silent CLI default (antigravity is exempt). Model ids churn — verify against
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
    """
  end

  attr(:model_catalogs, :list, required: true)

  @doc """
  Operator-editable model-id catalog per agent — add / remove ids and refresh
  from the agent CLI list when one is available.
  """
  @spec model_catalog_card(map()) :: Rendered.t()
  def model_catalog_card(assigns) do
    ~H"""
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
          <div class="catalog-models">
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
end
