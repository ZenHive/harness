defmodule Harness.Dashboard.MaintenanceLive do
  @moduledoc "Live fleet maintenance controls and chronological finding evidence."
  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.RunFeed
  alias Harness.Maintenance
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_, _, socket) do
    if connected?(socket) do
      Maintenance.subscribe()
      RunFeed.subscribe()
    end

    {:ok, assign(socket, project: nil, id: nil, notice: nil, offset: 0)}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(params, _, socket) do
    offset =
      case Integer.parse(params["offset"] || "0") do
        {n, ""} when n >= 0 -> n
        _ -> 0
      end

    {:noreply, socket |> assign(project: params["project"], id: params["id"], offset: offset) |> refresh()}
  end

  @impl Phoenix.LiveView
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(:maintenance_updated, socket), do: {:noreply, refresh(socket)}

  def handle_info({event, _}, socket) when event in [:harness_run_update, :harness_run_settled],
    do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("save", params, socket) do
    result =
      Maintenance.configure(
        socket.assigns.project,
        params["enabled"] == "true",
        integer(params["cadence_minutes"]),
        params["agent"],
        params["model"],
        integer(params["deadline_seconds"])
      )

    notice =
      case result do
        :ok -> "Maintenance settings saved."
        {:error, reason} -> "Settings not saved: #{inspect(reason)}"
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  def handle_event("sweep", _, socket) do
    notice =
      case Maintenance.sweep_now(socket.assigns.project) do
        {:ok, _} -> "Sweep queued."
        {:error, reason} -> "Sweep unavailable: #{inspect(reason)}"
      end

    {:noreply, socket |> assign(:notice, notice) |> refresh()}
  end

  @spec integer(term()) :: integer() | nil
  defp integer(value) do
    case Integer.parse(value || "") do
      {n, ""} -> n
      _ -> nil
    end
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket) do
    project = socket.assigns.project
    history = if socket.assigns.id, do: Maintenance.history(socket.assigns.id, socket.assigns.offset)
    projects = ProjectRegistry.list()

    assign(socket,
      fleet: Enum.map(projects, &Maintenance.status(&1.name)),
      exists: Enum.any?(projects, &(&1.name == project)),
      status: if(project, do: Maintenance.status(project)),
      page: if(project, do: Maintenance.findings(project, socket.assigns.offset)),
      history: history,
      models: Harness.ModelAvailability.list_available_ids(:codex),
      links: task_links(project || get_in(history || %{}, ["finding", "project"]))
    )
  end

  @spec task_links(String.t() | nil) :: map()
  defp task_links(nil), do: %{}

  defp task_links(project) do
    case Harness.ResultStore.list_run_records(project_name: project, limit: 100) do
      {:ok, records} ->
        records
        |> Enum.reverse()
        |> Enum.flat_map(fn record ->
          Enum.map(Enum.uniq([record.task_id | record.task_ids]), &{to_string(&1), record})
        end)
        |> Map.new()

      _ ->
        %{"__error__" => true}
    end
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <Harness.Dashboard.InsightsStyles.styles />
    <style>
      .maintenance input { box-sizing: border-box; width: 100%; min-height: 44px; background: var(--surface-2); color: var(--text); border: 1px solid var(--rule-strong); border-radius: .35rem; padding: var(--space-2) var(--space-3); font: inherit; }
      .maintenance input:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
    </style>
    <div class="insights maintenance">
      <header class="insights-header">
        <div>
          <h1>Maintenance</h1><p class="insights-meta">
            Repository improvements, assessed against evidence
          </p>
        </div>
        <.link :if={@project || @id} navigate="/harness/maintenance">All repositories</.link>
      </header>
      <p :if={@notice} role="status">{@notice}</p>
      <p :if={not Harness.Maintenance.Store.persistent?()} class="insights-meta">
        Ephemeral — records are lost on restart. Scheduled sweeps require Postgres.
      </p>
      <section :if={@live_action == :index} aria-label="Repository maintenance">
        <p :if={@fleet == []} class="insights-empty">
          No registered repositories. Register a project to configure maintenance.
        </p>
        <article :for={repo <- @fleet} class="insights-row">
          <h2><.link navigate={repo_path(repo["project"])}>{repo["project"]}</.link></h2>
          <p>{repo["state"]} · Next sweep: {repo["next_sweep"] || "Disabled"}</p>
          <p class="insights-meta">
            Last result: {repo["progress"]["rationale"] || repo["progress"]["error"] ||
              "No completed sweep"}
          </p>
          <p class="insights-meta">
            Outstanding maintenance tasks: {repo["tasks"]["outstanding"] ||
              "Unknown — evidence unavailable"}
          </p>
          <p class="insights-meta">Progress: {repo["progress"]["state"] || "Not started"}</p>
        </article>
      </section>
      <section :if={@live_action == :repository && !@exists} class="insights-empty">
        Repository not found.
      </section>
      <section :if={@live_action == :repository && @exists} aria-label="Repository detail">
        <h2>{@project}</h2>
        <p>{@status["state"]} · Next sweep: {@status["next_sweep"] || "Disabled"}</p>
        <p :if={@status["progress"]["error"]} role="alert">
          Sweep failed: {@status["progress"]["error"]}
        </p>
        <p>{@status["progress"]["rationale"]}</p>
        <form id="maintenance-settings" phx-submit="save" class="insights-panel">
          <h3>Settings</h3>
          <div class="insights-fields">
            <div class="insights-field">
              <label for="maintenance-enabled">Maintenance</label>
              <select id="maintenance-enabled" name="enabled"><option
                value="false"
                selected={!@status["settings"]["enabled"]}
              >
                Disabled
              </option><option value="true" selected={@status["settings"]["enabled"]}>Enabled</option></select>
            </div>
            <div class="insights-field">
              <label for="maintenance-cadence">Cadence in minutes</label><input
                id="maintenance-cadence"
                type="number"
                name="cadence_minutes"
                min="60"
                max="525600"
                required
                value={@status["settings"]["cadence_minutes"]}
              /><span class="insights-meta">Weekly: 10080 minutes</span>
            </div>
            <div class="insights-field">
              <label for="maintenance-agent">Agent</label><select id="maintenance-agent" name="agent"><option value="codex">
                Codex
              </option></select>
            </div>
            <div class="insights-field">
              <label for="maintenance-model">Pinned model</label><select
                id="maintenance-model"
                name="model"
                required
              ><option value="">Select a model</option><option
                :for={model <- Enum.uniq([@status["settings"]["model"] | @models])}
                :if={model}
                value={model}
                selected={model == @status["settings"]["model"]}
              >
                {model}
              </option></select>
            </div>
            <div class="insights-field">
              <label for="maintenance-deadline">Deadline in seconds</label><input
                id="maintenance-deadline"
                type="number"
                name="deadline_seconds"
                min="60"
                max="3600"
                required
                value={@status["settings"]["deadline_seconds"]}
              />
            </div>
          </div>
          <button class="btn-save" type="submit" phx-disable-with="Saving…">Save settings</button>
        </form>
        <button
          class="btn-save"
          phx-click="sweep"
          phx-disable-with="Queuing…"
          disabled={!@status["settings"]["enabled"]}
        >Sweep now</button>
        <h3>Published tasks</h3>
        <p :if={@status["tasks"]["error"]} role="status">
          Task state unavailable: {@status["tasks"]["error"]}.
        </p>
        <p :for={task <- @status["tasks"]["items"]}>
          {task["id"]} · {task["title"]} · {task["status"]}
        </p>
        <h3>Findings and tasks</h3>
        <p :if={@page["items"] == []} class="insights-empty">
          No findings recorded. A successful sweep may find no justified work.
        </p>
        <article :for={finding <- @page["items"]} class="insights-row">
          <h3>
            <.link navigate={"/harness/maintenance/findings/" <> finding["id"]}>{finding["title"]}</.link>
          </h3>
          <p>{finding["category"]} · {if finding["blocked"], do: "Blocked", else: "Assessed"}</p>
          <p>{finding["rationale"]}</p>
          <.task_state finding={finding} links={@links} />
        </article>
        <.link
          :if={@page["next_offset"]}
          patch={repo_path(@project) <> "?offset=" <> to_string(@page["next_offset"])}
        >Older findings</.link>
      </section>
      <section :if={@live_action == :finding} aria-label="Finding history">
        <p :if={!@history["finding"]} class="insights-empty">Finding not found.</p>
        <div :if={@history["finding"]}>
          <h2>{@history["finding"]["title"]}</h2>
          <.link navigate={repo_path(@history["finding"]["project"])}>Repository detail</.link>
          <.task_state finding={@history["finding"]} links={@links} />
          <h3>Assessment history</h3>
          <ol class="insights-history">
            <li :for={revision <- @history["revisions"]} class="insights-revision">
              <p class="insights-meta">
                {revision["assessment_at"] || revision["at"]} · {revision["agent"]} / {revision[
                  "model"
                ]} · Source {revision[
                  "source_revision"
                ]}
              </p>
              <h4>Evidence</h4><p class="insights-prose">{revision["evidence"]}</p>
              <h4>AI rationale</h4><p class="insights-prose">{revision["rationale"]}</p>
              <h4>Proposed improvement</h4><p class="insights-prose">{revision["improvement"]}</p>
              <h4>Outcome and measurements</h4><p class="insights-prose">{revision["outcome"]}</p>
            </li>
          </ol>
          <.link
            :if={@history["next_offset"]}
            patch={"/harness/maintenance/findings/" <> @id <> "?offset=" <> to_string(@history["next_offset"])}
          >Older assessments</.link>
        </div>
      </section>
    </div>
    """
  end

  attr :finding, :map, required: true
  attr :links, :map, required: true
  @spec task_state(map()) :: Rendered.t()
  defp task_state(assigns) do
    assigns = assign(assigns, :run, assigns.links[assigns.finding["task_id"]])

    ~H"""
    <p :if={@links["__error__"]} role="status">Run history unavailable.</p>
    <p :if={!@finding["task_id"]} class="insights-meta">Retained for reassessment · Not published</p>
    <p :if={@finding["task_id"]} class="insights-meta">
      Task {@finding["task_id"]}
      <.link :if={@run} navigate={"/harness/runs/" <> @run.run_id}>Implementation / review: {@run.verdict ||
        "In progress"}</.link>
      <span :if={@run}> · Landing: {@run.landed_sha || "Not landed"}</span>
      <span :if={!@run && !@links["__error__"]}> · Awaiting execution under repository policy</span>
    </p>
    """
  end

  @spec repo_path(String.t()) :: String.t()
  defp repo_path(project), do: "/harness/maintenance/repositories/" <> URI.encode_www_form(project)
end
