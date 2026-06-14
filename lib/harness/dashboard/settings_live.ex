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
  alias Harness.Dashboard.SettingsComponents
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ModelAvailability
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Socket

  require Logger

  @meta_tick_interval_ms 5_000

  # Ordered tab definitions ({key, label}) for the in-page section nav. The key
  # is matched against the `:tab` assign to toggle each panel's `hidden`. Panels
  # stay in the DOM (toggled, not `:if`-removed) so the full page is one render.
  @tabs [
    {"autonomy", "Autonomy"},
    {"agents", "Agents"},
    {"models", "Models"},
    {"projects", "Projects"},
    {"advanced", "Advanced"}
  ]
  @default_tab "autonomy"
  @valid_tabs Map.new(@tabs, fn {key, _label} -> {key, true} end)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_meta_tick()

    {:ok,
     socket
     |> assign(:notice, nil)
     |> assign(:tabs, @tabs)
     |> assign(:tab, @default_tab)
     |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info(:meta_tick, socket) do
    schedule_meta_tick()
    {:noreply, refresh(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("set_tab", %{"tab" => tab}, socket) when is_map_key(@valid_tabs, tab) do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("set_tab", _params, socket), do: {:noreply, socket}

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

  def handle_event("set_concurrency", %{"name" => name, "concurrency_cap" => raw_cap}, socket) do
    notice =
      with {:ok, project} <- ProjectRegistry.lookup(name),
           {:ok, cap} <- parse_concurrency_cap(raw_cap),
           :ok <- ProjectRegistry.upsert(%{project | concurrency_cap: cap}) do
        {:ok, "Concurrency updated for #{name}."}
      else
        {:error, {:unknown_project, _name}} -> {:error, "Unknown project."}
        :error -> {:error, "Concurrency cap must be a positive integer or blank."}
        {:error, _reason} -> {:error, "Could not update concurrency for #{name}."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("save_project", params, socket) do
    notice =
      with {:ok, attrs} <- project_attrs(params),
           :ok <- ProjectRegistry.upsert(attrs) do
        {:ok, "Project #{attrs.name} saved."}
      else
        :error -> {:error, "Project name, source, and roadmap path are required."}
        {:error, _reason} -> {:error, "Could not save project."}
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("unregister_project", %{"name" => name}, socket) do
    notice =
      case ProjectRegistry.unregister(name) do
        :ok -> {:ok, "Project #{name} removed."}
        {:error, {:unknown_project, _name}} -> {:error, "Unknown project."}
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

      <nav class="settings-tabs" role="tablist" aria-label="Settings sections">
        <button
          :for={{key, label} <- @tabs}
          type="button"
          class="settings-tab"
          role="tab"
          data-active={to_string(@tab == key)}
          aria-selected={to_string(@tab == key)}
          phx-click="set_tab"
          phx-value-tab={key}
        >
          {label}
        </button>
      </nav>

      <Components.operator_flash notice={@notice} include_persistent={false} />

      <section class="settings-panel" data-tab="autonomy" hidden={@tab != "autonomy"}>
        <SettingsComponents.cron_autonomy_card autonomy={@autonomy} />
        <SettingsComponents.project_autonomy_card autonomy={@autonomy} />
      </section>

      <section class="settings-panel" data-tab="agents" hidden={@tab != "agents"}>
        <SettingsComponents.agents_card agents={@agents} />
        <SettingsComponents.project_reviewers_card reviewers={@reviewers} />
        <SettingsComponents.dispatch_default_card dispatch={@dispatch} />
      </section>

      <section class="settings-panel" data-tab="models" hidden={@tab != "models"}>
        <SettingsComponents.agent_models_card agent_models={@agent_models} />
        <SettingsComponents.reviewer_models_card reviewer_models={@reviewer_models} />
        <SettingsComponents.model_catalog_card model_catalogs={@model_catalogs} />
      </section>

      <section class="settings-panel" data-tab="projects" hidden={@tab != "projects"}>
        <Components.landing_card projects={@landing} />
        <Components.project_settings_card projects={@projects} />
      </section>

      <section class="settings-panel" data-tab="advanced" hidden={@tab != "advanced"}>
        <Components.config_form entries={@config_edit} />
        <Components.config_inspector sections={@config} />
      </section>
    </div>
    """
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket) do
    projects = ProjectRegistry.list()

    socket
    |> assign(:autonomy, autonomy_state(projects))
    |> assign(:agents, agents_state())
    |> assign(:landing, landing_state(projects))
    |> assign(:projects, project_state(projects))
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

  # A free-text model pin: blank clears the override (the resolver then rejects a
  # model-capable agent as model_required; only antigravity runs model-less),
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

  @spec project_state([Project.t()]) :: [map()]
  defp project_state(projects) do
    Enum.map(projects, fn project ->
      {source_type, source_location} = project_source(project)
      cap = config_input_value(project.concurrency_cap)

      %{
        name: project.name,
        label: project.name,
        source_type: source_type,
        source_location: source_location,
        roadmap_path: project.roadmap_path,
        check_command: project.check_command || "",
        target_branch: project.target_branch || "",
        concurrency_cap: cap,
        concurrency_label: if(cap == "", do: "default", else: cap)
      }
    end)
  end

  @spec project_source(Project.t()) :: {String.t(), String.t()}
  defp project_source(%Project{source: {:local, path}}), do: {"local", path}
  defp project_source(%Project{source: {:github, url}}), do: {"github", url}

  @spec project_attrs(map()) :: {:ok, map()} | :error
  defp project_attrs(params) do
    with {:ok, name} <- required_param(params, "name"),
         {:ok, source} <- source_param(params),
         {:ok, roadmap_path} <- required_param(params, "roadmap_path"),
         {:ok, cap} <- parse_concurrency_cap(Map.get(params, "concurrency_cap", "")) do
      {:ok,
       name
       |> preserved_project_attrs()
       |> Map.merge(%{
         name: name,
         source: source,
         roadmap_path: roadmap_path,
         check_command: optional_param(params, "check_command"),
         target_branch: optional_param(params, "target_branch"),
         concurrency_cap: cap
       })}
    end
  end

  @spec preserved_project_attrs(String.t()) :: map()
  defp preserved_project_attrs(name) do
    case ProjectRegistry.lookup(name) do
      {:ok, project} ->
        %{
          landing_policy: project.landing_policy,
          pollution_allowlist: project.pollution_allowlist,
          reviewer: project.reviewer,
          warm_paths: project.warm_paths
        }

      {:error, _reason} ->
        %{}
    end
  end

  @spec source_param(map()) :: {:ok, Project.source()} | :error
  defp source_param(params) do
    with {:ok, location} <- required_param(params, "source_location") do
      case Map.get(params, "source_type") do
        "local" -> {:ok, {:local, location}}
        "github" -> {:ok, {:github, location}}
        _other -> :error
      end
    end
  end

  @spec required_param(map(), String.t()) :: {:ok, String.t()} | :error
  defp required_param(params, key) do
    case optional_param(params, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  @spec optional_param(map(), String.t()) :: String.t() | nil
  defp optional_param(params, key) do
    case params |> Map.get(key, "") |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @spec parse_concurrency_cap(String.t()) :: {:ok, pos_integer() | nil} | :error
  defp parse_concurrency_cap(raw) do
    case String.trim(raw) do
      "" -> {:ok, nil}
      value -> parse_positive_integer(value)
    end
  end

  @spec parse_positive_integer(String.t()) :: {:ok, pos_integer()} | :error
  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _unparseable -> :error
    end
  end

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

  @spec schedule_meta_tick() :: reference()
  defp schedule_meta_tick, do: Process.send_after(self(), :meta_tick, @meta_tick_interval_ms)
end
