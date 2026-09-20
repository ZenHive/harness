defmodule Harness.Dashboard.InsightsLive do
  @moduledoc "Live observation overview, evidence and revision history."
  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Insights
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Socket

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: Insights.subscribe()
    {:ok, assign(socket, project: "", run_id: "", id: nil, offset: 0, notice: nil)}
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

    notice = if result == :ok, do: "Observer settings saved.", else: "Invalid observer settings."
    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket) do
    assign(socket,
      status: Insights.status(),
      projects: ProjectRegistry.list(),
      page: Insights.findings(socket.assigns.project, socket.assigns.run_id, socket.assigns.offset),
      history: if(socket.assigns.id, do: Insights.history(socket.assigns.id, socket.assigns.offset))
    )
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <header class="settings-head">
      <h1>Run Insights</h1>
      <p class="settings-sub">AI observations across runs</p>
    </header>
    <p :if={@notice} role="status">{@notice}</p>
    <p :if={@status["ephemeral"]} role="status">
      Ephemeral — observations disappear on restart. Scheduled observation requires Postgres.
    </p>
    <section aria-label="Observer status">
      <p role="status">{state_label(@status["state"])}</p>
      <dl class="field">
        <dt>Observer</dt><dd>{@status["settings"]["agent"]} / {@status["settings"]["model"]}</dd>
        <dt>Last successful pass</dt><dd>{@status["last_success"] || "Never"}</dd>
        <dt>Next pass</dt><dd>{@status["next_pass"] || "Paused"}</dd>
        <dt>Progress</dt><dd>{@status["progress"]["scanned"] || 0} run snapshots examined</dd>
      </dl>
      <p :if={@status["last_pass"] && @status["last_pass"]["error"]} role="alert">
        {@status["last_pass"]["error"]}
      </p>
      <button
        type="button"
        phx-click="observe"
        disabled={!@status["settings"]["enabled"] || @status["ephemeral"]}
      >Observe now</button>
      <.link navigate="/harness/insights/settings">Observer settings</.link>
    </section>

    <section :if={@live_action == :settings} aria-label="Run Insights settings">
      <h2>Independent observer settings</h2>
      <form id="insights-settings" phx-submit="save">
        <label for="insights-enabled">Observation</label>
        <select id="insights-enabled" name="enabled">
          <option value="false" selected={!@status["settings"]["enabled"]}>Paused</option>
          <option value="true" selected={@status["settings"]["enabled"]}>Enabled</option>
        </select>
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
            selected={minutes == @status["settings"]["cadence_minutes"]}
          >
            {label}
          </option>
        </select>
        <label for="insights-agent">Agent</label>
        <select id="insights-agent" name="agent"><option value="claude">Claude (tool-free)</option></select>
        <label for="insights-model">Model</label>
        <input
          id="insights-model"
          name="model"
          value={@status["settings"]["model"]}
          required
          maxlength="120"
        />
        <button type="submit">Save observer settings</button>
      </form>
      <p>
        Only Claude's verified tool-free invocation is available. Dispatch autonomy is independent.
      </p>
    </section>

    <section :if={@live_action == :index} aria-label="Findings">
      <form id="insights-filter" phx-change="filter">
        <label for="insights-project">Project</label>
        <select id="insights-project" name="project">
          <option value="">All projects</option>
          <option :for={project <- @projects} value={project.name} selected={project.name == @project}>
            {project.name}
          </option>
        </select>
      </form>
      <p :if={@run_id != ""}>Findings related to run {@run_id}</p>
      <p :if={@page["items"] == []}>No findings in this page for the selected filters.</p>
      <article :for={finding <- @page["items"]} class="run-section">
        <h2><.link navigate={"/harness/insights/" <> finding["id"]}>{finding["title"]}</.link></h2>
        <p>{finding["explanation"]}</p>
        <p><strong>AI assessment:</strong> {finding["assessment"]}</p>
        <p :if={finding["provisional"]}>Provisional — includes active-run evidence.</p>
        <.link navigate={"/harness/insights/" <> finding["id"]}>{length(finding["citations"])} linked evidence excerpts</.link>
      </article>
      <.link
        :if={@page["next_offset"]}
        patch={"/harness/insights?" <> URI.encode_query(%{"project" => @project, "run_id" => @run_id, "offset" => @page["next_offset"]})}
      >Next findings page</.link>
    </section>

    <section :if={@live_action == :show} aria-label="Finding history">
      <.link navigate="/harness/insights">All findings</.link>
      <p :if={!@history["finding"]}>Finding not found.</p>
      <div :if={@history["finding"]}>
        <h2>{@history["finding"]["title"]}</h2>
        <p>{@history["finding"]["explanation"]}</p>
        <h3>Proposed improvement</h3><p>{@history["finding"]["improvement"]}</p>
        <p>Advisory only. A merged fix alone does not establish resolution.</p>
        <h3>Revisions</h3>
        <article :for={revision <- @history["revisions"]} class="run-section">
          <p>
            <time>{revision["at"]}</time>
            · {revision["observer"]["agent"]} / {revision["observer"]["model"]}
          </p>
          <p :if={revision["provisional"]}>Provisional — active-run evidence</p>
          <h4>Source facts</h4><p>{revision["facts"]}</p>
          <h4>AI hypothesis</h4><p>{revision["hypothesis"]}</p>
          <h4>Current assessment</h4><p>{revision["assessment"]}</p>
          <h4>Contradictions</h4><p>{revision["contradictions"]}</p>
          <h4>Recurrence</h4><p>{revision["recurrence"]}</p>
          <h4>Proposed improvement</h4><p>{revision["improvement"]}</p>
          <details :for={citation <- revision["citations"]} open>
            <summary>
              <.link navigate={"/harness/runs/" <> citation["run_id"]}>{citation["run_id"]}</.link>
              · {citation["field"]} · {citation["availability"]}
            </summary>
            <blockquote>{citation["excerpt"]}</blockquote>
          </details>
        </article>
        <.link
          :if={@history["next_offset"]}
          patch={"/harness/insights/" <> @id <> "?offset=" <> to_string(@history["next_offset"])}
        >Older revisions</.link>
      </div>
    </section>
    """
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
end
