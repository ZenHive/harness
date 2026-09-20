defmodule Harness.Dashboard.InsightsLive do
  @moduledoc "Live observation overview, evidence and revision history."
  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Insights
  alias Harness.Insights.Selection
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Socket

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: Insights.subscribe()
    {:ok, assign(socket, project: "", run_id: "", id: nil, offset: 0, notice: nil, draft: nil)}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(params, _uri, socket) do
    offset =
      case Integer.parse(params["offset"] || "0") do
        {value, ""} when value >= 0 -> value
        _ -> 0
      end

    {:noreply,
     socket
     |> assign(project: params["project"] || "", run_id: params["run_id"] || "", id: params["id"], offset: offset)
     |> refresh()}
  end

  @impl Phoenix.LiveView
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(:insights_updated, socket), do: {:noreply, refresh(socket)}

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("filter", %{"project" => project}, socket) do
    {:noreply, push_patch(socket, to: "/harness/insights?" <> URI.encode_query(%{"project" => project}))}
  end

  def handle_event("observe", _, socket) do
    notice =
      case Insights.observe_now() do
        {:ok, _id} -> "Observation queued."
        {:error, reason} -> "Observation unavailable: #{reason}"
      end

    {:noreply, assign(socket, :notice, notice)}
  end

  def handle_event("change_settings", params, socket) do
    params = Map.take(params, ["enabled", "cadence_minutes", "agent", "model"])
    params = if params["agent"] == socket.assigns.draft["agent"], do: params, else: Map.put(params, "model", "")
    {:noreply, assign(socket, draft: params, notice: nil)}
  end

  def handle_event("save", params, socket) do
    cadence =
      case Integer.parse(params["cadence_minutes"] || "") do
        {value, ""} -> value
        _ -> nil
      end

    result =
      Insights.configure(%{
        "enabled" => params["enabled"] == "true",
        "cadence_minutes" => cadence,
        "agent" => params["agent"],
        "model" => params["model"]
      })

    notice =
      case result do
        :ok -> "Observer settings saved."
        {:error, reason} -> "Settings not saved: #{selection_message(reason)}"
      end

    {:noreply, socket |> assign(notice: notice, draft: params) |> refresh()}
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket) do
    assign(socket,
      status: Insights.status(),
      choices: Selection.choices(),
      draft: socket.assigns.draft || Insights.settings(),
      projects: ProjectRegistry.list(),
      page: Insights.findings(socket.assigns.project, socket.assigns.run_id, socket.assigns.offset),
      history: if(socket.assigns.id, do: Insights.history(socket.assigns.id, socket.assigns.offset))
    )
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Harness.Dashboard.InsightsStyles.styles />
    <div class="insights">
      <header class="insights-header">
        <div>
          <h1>Run Insights</h1><p class="insights-meta">AI observations across runs</p>
        </div>
        <div class="insights-actions">
          <button
            :if={@live_action == :index}
            class="btn-dispatch"
            type="button"
            phx-click="observe"
            phx-disable-with="Queuing…"
            disabled={observe_blocked?(@status)}
            title={observe_block_reason(@status)}
          >Observe now</button>
          <.link
            :if={@live_action != :settings}
            class="btn-save"
            navigate="/harness/insights/settings"
          >Observer settings</.link>
          <.link :if={@live_action == :settings} class="btn-save" navigate="/harness/insights">Back to findings</.link>
        </div>
      </header>
      <p :if={@notice} class="insights-notice" role="status">{@notice}</p>
      <p :if={@status["ephemeral"]} class="insights-notice insights-meta" role="status">
        Ephemeral — observations disappear on restart. Scheduled observation requires Postgres.
      </p>
      <p :if={@status["selection_error"]} class="insights-notice" role="alert">
        {selection_message(@status["selection_error"])} Configure an available observer in settings.
      </p>

      <section
        :if={@live_action == :index}
        class="insights-panel"
        data-state={@status["state"]}
        aria-label="Observer status"
      >
        <h2>{state_label(@status["state"])}</h2>
        <dl class="insights-summary">
          <div>
            <dt>Observer</dt><dd>
              {@status["settings"]["agent"]} / {@status["settings"]["model"] || "Select a model"}
            </dd>
          </div>
          <div>
            <dt>Evidence examined</dt><dd>{@status["progress"]["scanned"] || 0} run snapshots</dd>
          </div>
          <div>
            <dt>Last successful pass</dt><dd>{display_time(@status["last_success"], "Never")}</dd>
          </div>
          <div>
            <dt>Next pass</dt><dd>{display_time(@status["next_pass"], "Paused")}</dd>
          </div>
        </dl>
        <p :if={@status["last_pass"] && @status["last_pass"]["error"]} role="alert">
          {@status["last_pass"]["error"]}
        </p>
      </section>

      <section
        :if={@live_action == :settings}
        class="insights-panel"
        aria-label="Run Insights settings"
      >
        <h2>Independent observer settings</h2>
        <p class="insights-meta">
          Choose an enabled agent and an available model. Observation is advisory and does not change dispatch autonomy.
        </p>
        <form id="insights-settings" phx-submit="save" phx-change="change_settings">
          <div class="insights-fields">
            <div class="insights-field">
              <label for="insights-enabled">Observation</label>
              <select id="insights-enabled" name="enabled">
                <option value="false" selected={to_string(@draft["enabled"]) != "true"}>
                  Paused
                </option>
                <option value="true" selected={to_string(@draft["enabled"]) == "true"}>
                  Enabled
                </option>
              </select>
              <span class="insights-meta">Enable only when you are ready for scheduled passes.</span>
            </div>
            <div class="insights-field">
              <label for="insights-cadence">Cadence</label>
              <select id="insights-cadence" name="cadence_minutes">
                <option
                  :for={
                    {minutes, label} <- [
                      {15, "Every 15 minutes"},
                      {60, "Hourly"},
                      {360, "Every 6 hours"},
                      {1440, "Daily"}
                    ]
                  }
                  value={minutes}
                  selected={to_string(minutes) == to_string(@draft["cadence_minutes"])}
                >
                  {label}
                </option>
              </select>
              <span class="insights-meta">Failed attempts retain this cadence after retries.</span>
            </div>
            <div class="insights-field">
              <label for="insights-agent">Agent</label>
              <select id="insights-agent" name="agent" required>
                <option
                  :if={!Enum.any?(@choices, &(&1.agent == @draft["agent"]))}
                  value={@draft["agent"]}
                  selected
                >
                  {@draft["agent"]} — unavailable
                </option>
                <option
                  :for={choice <- @choices}
                  value={choice.agent}
                  selected={choice.agent == @draft["agent"]}
                >
                  {String.capitalize(choice.agent)}
                </option>
              </select>
              <span class="insights-meta">Codex uses a read-only sandbox. Claude uses its tool-free mode.</span>
            </div>
            <div class="insights-field">
              <label for="insights-model">Model</label>
              <select id="insights-model" name="model" required>
                <option value="" selected={@draft["model"] in [nil, ""]}>Select a model</option>
                <option
                  :if={
                    @draft["model"] not in [nil, ""] and
                      @draft["model"] not in models(@choices, @draft["agent"])
                  }
                  value={@draft["model"]}
                  selected
                >
                  {@draft["model"]} — unavailable
                </option>
                <option
                  :for={model <- models(@choices, @draft["agent"])}
                  value={model}
                  selected={model == @draft["model"]}
                >
                  {model}
                </option>
              </select>
              <span class="insights-meta">Available models from the selected agent catalog. No provider fallback.</span>
            </div>
          </div>
          <div class="insights-actions">
            <button class="btn-save" type="submit" phx-disable-with="Saving…">Save observer settings</button>
          </div>
        </form>
      </section>

      <section :if={@live_action == :index} aria-label="Findings">
        <div class="insights-toolbar">
          <h2>Findings</h2>
          <form id="insights-filter" phx-change="filter" class="insights-field">
            <label for="insights-project">Project</label>
            <select id="insights-project" name="project">
              <option value="">All projects</option>
              <option
                :if={@project != "" and not Enum.any?(@projects, &(&1.name == @project))}
                value={@project}
                selected
              >
                {@project}
              </option>
              <option
                :for={project <- @projects}
                value={project.name}
                selected={project.name == @project}
              >
                {project.name}
              </option>
            </select>
          </form>
        </div>
        <p :if={@run_id != ""} class="insights-meta">Findings related to run {@run_id}</p>
        <div :if={@page["items"] == []} class="insights-empty">
          <%= cond do %>
            <% @project != "" or @run_id != "" or @offset > 0 -> %>
              <h2>No findings match this view</h2><p>
                Clear the filters to see findings across projects.
              </p>
              <div class="insights-actions">
                <.link class="btn-save" patch="/harness/insights">Clear filters</.link>
              </div>
            <% !@status["settings"]["enabled"] or !@status["last_pass"] -> %>
              <h2>Your run history has more to tell</h2>
              <p>
                Run Insights reviews evidence across runs to track recurring problems and revisit earlier findings. Choose an observer and enable a cadence to begin.
              </p>
              <div class="insights-actions">
                <.link class="btn-save" navigate="/harness/insights/settings">Configure observation</.link>
              </div>
            <% true -> %>
              <h2>No findings published yet</h2><p>
                The latest pass status appears above. Findings will appear here when an observation identifies supported patterns.
              </p>
          <% end %>
        </div>
        <article :for={finding <- @page["items"]} class="insights-row">
          <h2><.link navigate={"/harness/insights/" <> finding["id"]}>{finding["title"]}</.link></h2>
          <p class="insights-prose">{finding["explanation"]}</p>
          <p class="insights-prose"><strong>AI assessment:</strong> {finding["assessment"]}</p>
          <p :if={finding["provisional"]} class="insights-meta">
            Provisional — includes active-run evidence.
          </p>
          <p class="insights-meta">
            {Enum.join(finding["projects"], ", ")} · {display_time(finding["at"], "")} ·
            <.link navigate={"/harness/insights/" <> finding["id"]}>
              {length(finding["citations"])} linked evidence excerpts
            </.link>
          </p>
        </article>
        <.link
          :if={@page["next_offset"]}
          class="btn-save"
          patch={"/harness/insights?" <> URI.encode_query(%{"project" => @project, "run_id" => @run_id, "offset" => @page["next_offset"]})}
        >Next findings page</.link>
      </section>

      <section :if={@live_action == :show} aria-label="Finding history">
        <.link class="btn-save insights-back" navigate="/harness/insights">All findings</.link>
        <p :if={!@history["finding"]}>Finding not found.</p>
        <div :if={@history["finding"]}>
          <section class="insights-panel" aria-label="Current assessment">
            <h2>{@history["finding"]["title"]}</h2>
            <p class="insights-prose">{@history["finding"]["explanation"]}</p>
            <h3>Current assessment</h3>
            <p class="insights-prose">{@history["finding"]["assessment"]}</p>
            <h3>Proposed improvement</h3>
            <p class="insights-prose">{@history["finding"]["improvement"]}</p>
            <p class="insights-meta">
              Advisory only. A merged fix alone does not establish resolution.
            </p>
          </section>
          <h2>Evidence and revision history</h2>
          <p class="insights-meta">
            Chronological within this page. Open excerpts to inspect the retained evidence.
          </p>
          <ol class="insights-history">
            <li :for={revision <- @history["revisions"]}>
              <article class="insights-revision">
                <p class="insights-meta">
                  <time datetime={revision["at"]}>{display_time(revision["at"], "")}</time>
                  · {revision["observer"]["agent"]} / {revision["observer"]["model"]}
                </p>
                <p :if={revision["provisional"]} class="insights-meta">
                  Provisional — active-run evidence
                </p>
                <h3>{revision["title"]}</h3>
                <p class="insights-prose">{revision["explanation"]}</p>
                <dl class="insights-revision-facts">
                  <div>
                    <dt>Source facts</dt>
                    <dd>{revision["facts"]}</dd>
                  </div>
                  <div>
                    <dt>AI hypothesis</dt>
                    <dd>{revision["hypothesis"]}</dd>
                  </div>
                  <div>
                    <dt>Assessment at this revision</dt>
                    <dd>{revision["assessment"]}</dd>
                  </div>
                  <div>
                    <dt>Contradictions</dt>
                    <dd>{revision["contradictions"]}</dd>
                  </div>
                  <div>
                    <dt>Recurrence</dt>
                    <dd>{revision["recurrence"]}</dd>
                  </div>
                  <div>
                    <dt>Proposed improvement</dt>
                    <dd>{revision["improvement"]}</dd>
                  </div>
                </dl>
                <details :for={citation <- revision["citations"]}>
                  <summary>
                    {citation["run_id"]} · {citation["field"]} · {citation["availability"]}
                  </summary>
                  <blockquote>{citation["excerpt"]}</blockquote>
                  <p>
                    <.link navigate={"/harness/runs/" <> citation["run_id"]}>
                      Open run {citation["run_id"]}
                    </.link>
                  </p>
                </details>
              </article>
            </li>
          </ol>
          <.link
            :if={@history["next_offset"]}
            class="btn-save"
            patch={"/harness/insights/" <> @id <> "?offset=" <> to_string(@history["next_offset"])}
          >Older revisions</.link>
        </div>
      </section>
    </div>
    """
  end

  @spec models([map()], String.t()) :: [String.t()]
  defp models(choices, agent),
    do: Enum.flat_map(choices, fn choice -> if choice.agent == agent, do: choice.models, else: [] end)

  @spec display_time(String.t() | nil, String.t()) :: String.t()
  defp display_time(nil, empty), do: empty

  defp display_time(time, _empty) do
    case DateTime.from_iso8601(time) do
      {:ok, date, _} -> Calendar.strftime(date, "%d %b %Y, %H:%M UTC")
      _ -> time
    end
  end

  @spec selection_message(term()) :: String.t()
  defp selection_message(reason) do
    case to_string(reason) do
      "agent_disabled" -> "The selected agent is disabled."
      "agent_unavailable" -> "The selected agent is unavailable."
      "model_required" -> "Select an available model."
      "model_unavailable" -> "The selected model is unavailable in the agent catalog."
      "unsupported_observer" -> "Choose Codex or Claude."
      _ -> "Check the observation and cadence fields."
    end
  end

  @spec state_label(String.t()) :: String.t()
  defp state_label("disabled"), do: "Paused — observation is disabled"
  defp state_label("observing"), do: "Observing"
  defp state_label("no_new_evidence"), do: "No new evidence in the examined page"
  defp state_label("no_findings"), do: "Successful pass — no findings"
  defp state_label("partial"), do: "Partial evidence — the available window is incomplete"
  defp state_label("failed"), do: "Observation failed — successful progress was preserved"
  defp state_label("successful"), do: "Observation complete"
  defp state_label("ready"), do: "Ready to observe"
  defp state_label(_other), do: "Ready to observe"

  @spec observe_blocked?(map()) :: boolean()
  defp observe_blocked?(status) do
    !status["settings"]["enabled"] || status["ephemeral"] ||
      status["selection_error"] != nil || status["state"] == "observing"
  end

  @spec observe_block_reason(map()) :: String.t() | nil
  defp observe_block_reason(status) do
    cond do
      status["ephemeral"] -> "Scheduled observation requires Postgres."
      status["selection_error"] != nil -> selection_message(status["selection_error"])
      !status["settings"]["enabled"] -> "Observation is paused."
      status["state"] == "observing" -> "An observation is already running."
      true -> nil
    end
  end
end
