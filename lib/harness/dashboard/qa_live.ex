defmodule Harness.Dashboard.QALive do
  @moduledoc "QA overview, bounded evidence and explicit audit queue controls."
  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Audit.QA, as: Attempts
  alias Harness.Audit.Requests
  alias Harness.Dashboard.QA
  alias Harness.ProjectRegistry
  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_qa, 10_000)

    {:ok,
     assign(socket,
       page: AsyncResult.loading(),
       name: nil,
       project_filter: "",
       status_filter: "",
       offset: 0,
       notice: nil,
       busy: false,
       evidence: nil,
       evidence_id: nil,
       evidence_offset: 0
     )}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       page: AsyncResult.loading(),
       name: params["name"],
       project_filter: params["project"] || "",
       status_filter: params["status"] || "",
       offset: offset(params["offset"]),
       evidence: nil,
       evidence_id: nil,
       evidence_offset: 0
     )
     |> refresh()}
  end

  @impl Phoenix.LiveView
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(:refresh_qa, socket) do
    Process.send_after(self(), :refresh_qa, 10_000)
    {:noreply, if(socket.assigns.page.loading, do: socket, else: refresh(socket))}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("filter", params, socket) do
    query = URI.encode_query(Map.take(params, ["project", "status"]))
    {:noreply, push_patch(socket, to: "/harness/qa?" <> query)}
  end

  def handle_event("refresh", _, socket), do: {:noreply, refresh(socket)}
  def handle_event("start", _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("start", _, %{assigns: %{name: name}} = socket) when is_binary(name) do
    {:noreply,
     socket
     |> assign(busy: true, notice: "Submitting QA request…")
     |> start_async(:enqueue, fn -> Requests.enqueue(name) end)}
  end

  def handle_event("evidence", %{"id" => id}, socket) do
    {:noreply, load_evidence(socket, id, 0)}
  end

  def handle_event("evidence_page", %{"direction" => direction}, socket) do
    delta = if direction == "next", do: 8_000, else: -8_000
    {:noreply, load_evidence(socket, socket.assigns.evidence_id, max(0, socket.assigns.evidence_offset + delta))}
  end

  @impl Phoenix.LiveView
  @spec handle_async(term(), term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_async(:enqueue, {:ok, {:ok, job}}, socket) do
    notice = if job.conflict?, do: "QA job #{job.id} is already active.", else: "QA job #{job.id} queued."
    {:noreply, socket |> assign(busy: false, notice: notice) |> refresh()}
  end

  def handle_async(:enqueue, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, busy: false, notice: "QA request failed: #{inspect(reason)}")}
  end

  def handle_async(:enqueue, {:exit, reason}, socket) do
    {:noreply, assign(socket, busy: false, notice: "QA request failed: #{inspect(reason)}")}
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket) do
    name = socket.assigns.name
    project = socket.assigns.project_filter
    status = socket.assigns.status_filter
    offset = socket.assigns.offset

    assign_async(socket, :page, fn ->
      if name do
        with {:ok, registered} <- ProjectRegistry.lookup(name) do
          {:ok, %{page: %{detail: QA.project(registered, 10)}}}
        end
      else
        {:ok, %{page: QA.page(project, status, offset)}}
      end
    end)
  end

  @spec load_evidence(Socket.t(), String.t(), non_neg_integer()) :: Socket.t()
  defp load_evidence(socket, id, offset) do
    name = socket.assigns.name

    socket
    |> assign(evidence: AsyncResult.loading(), evidence_id: id, evidence_offset: offset)
    |> assign_async(:evidence, fn ->
      with {:ok, detail} <- Attempts.detail(name, id),
           {:ok, page} <- Attempts.evidence(id, offset) do
        {:ok, %{evidence: Map.put(page, :detail, detail)}}
      end
    end)
  end

  @spec available_checks(String.t() | nil) :: String.t() | nil
  defp available_checks(value) when value in [nil, "null", "[]", "{}", "\"\""], do: nil
  defp available_checks(value), do: value

  @spec offset(term()) :: non_neg_integer()
  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp offset(_), do: 0

  @spec path(String.t()) :: String.t()
  defp path(name), do: "/harness/qa/" <> URI.encode(name, &URI.char_unreserved?/1)

  @spec page_path(map(), integer()) :: String.t()
  defp page_path(assigns, offset),
    do:
      "/harness/qa?" <>
        URI.encode_query(%{project: assigns.project_filter, status: assigns.status_filter, offset: max(0, offset)})

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <Harness.Dashboard.InsightsStyles.styles />
    <main class="insights" id="qa-dashboard">
      <header class="insights-header">
        <div>
          <h1>Quality assurance</h1><p>
            Full-project QA across registered projects. Results are tied to their command and revision.
          </p>
        </div>
        <.link navigate="/harness/settings" class="btn-save">Edit QA commands in Settings</.link>
      </header>
      <p :if={@notice} role="status" class="insights-notice">{@notice}</p>
      <.link :if={@name} patch="/harness/qa" class="insights-back">All QA projects</.link>
      <p :if={@page.loading} role="status">Loading QA facts…</p>
      <div :if={@page.failed} role="alert">
        <p>QA facts unavailable: {inspect(@page.failed)}</p><button
          phx-click="refresh"
          class="btn-save"
        >Retry loading</button>
      </div>
      <div :if={@page.ok? and !@page.failed}>
        <%= if @name do %>
          <.project_detail row={@page.result.detail} busy={@busy} />
        <% else %>
          <form phx-change="filter" phx-submit="filter" class="insights-fields" id="qa-filters">
            <div class="insights-field">
              <label for="qa-project">Project</label>
              <select name="project" id="qa-project">
                <option value="">All projects</option>
                <option
                  :for={name <- @page.result.names}
                  value={name}
                  selected={name == @project_filter}
                >
                  {name}
                </option>
              </select>
            </div>
            <div class="insights-field">
              <label for="qa-status">Status or configuration</label>
              <select name="status" id="qa-status">
                <option
                  :for={
                    {value, label} <- [
                      {"", "All statuses"},
                      {"configured", "QA configured"},
                      {"not-configured", "QA not configured"},
                      {"queued", "Queued"},
                      {"running", "Running"},
                      {"passed", "Latest passed"},
                      {"failed", "Latest failed"},
                      {"incomplete", "Latest incomplete"},
                      {"not-run", "No attempts"},
                      {"unavailable", "Unavailable"}
                    ]
                  }
                  value={value}
                  selected={value == @status_filter}
                >
                  {label}
                </option>
              </select>
            </div>
          </form>
          <p :if={@page.result.rows == []} class="insights-empty">No projects match these filters.</p>
          <article :for={row <- @page.result.rows} id={"qa-project-" <> row.id} class="insights-row">
            <h2><.link patch={path(row.id)}>{row.id}</.link></h2>
            <.facts row={row} />
          </article>
          <nav class="insights-actions" aria-label="QA project pages">
            <.link :if={@offset > 0} patch={page_path(assigns, @offset - 25)}>Previous projects</.link>
            <.link :if={@offset + 25 < @page.result.total} patch={page_path(assigns, @offset + 25)}>Next projects</.link>
          </nav>
        <% end %>
      </div>
      <section :if={@evidence} id="qa-evidence" aria-label="Attempt evidence" class="insights-row">
        <h2>Durable evidence</h2>
        <p :if={@evidence.loading} role="status">Loading evidence…</p>
        <p :if={@evidence.failed} role="alert">Evidence unavailable: {inspect(@evidence.failed)}</p>
        <div :if={@evidence.ok?}>
          <p>
            Attempt {@evidence_id}. Agent-authored content; sections limited to 8,000 characters. No per-check verdict is inferred.
          </p>
          <h3>Agent report</h3><p class="insights-prose">
            {@evidence.result.detail.report || "Agent report unavailable."}
          </p>
          <h3>Check outcomes supplied by the agent</h3>
          <p class="insights-prose">
            {available_checks(@evidence.result.detail.checks) ||
              "Per-check detail unavailable. An overall result does not establish individual check outcomes."}
          </p>
          <h3>Agent evidence</h3><p class="insights-prose">
            {@evidence.result.detail.evidence || "Agent evidence unavailable."}
          </p>
          <details>
            <summary>
              Raw durable evidence — characters {@evidence.result.offset + 1}–{min(
                @evidence.result.offset + 8_000,
                @evidence.result.total
              )} of {@evidence.result.total}
            </summary>
            <blockquote>{@evidence.result.evidence}</blockquote>
          </details>
          <div class="insights-actions">
            <button
              :if={@evidence_offset > 0}
              phx-click="evidence_page"
              phx-value-direction="previous"
              class="btn-save"
            >Previous evidence</button>
            <button
              :if={@evidence_offset + 8_000 < @evidence.result.total}
              phx-click="evidence_page"
              phx-value-direction="next"
              class="btn-save"
            >Next evidence</button>
          </div>
        </div>
      </section>
    </main>
    """
  end

  attr :row, :map, required: true
  @spec facts(map()) :: Rendered.t()
  defp facts(assigns) do
    ~H"""
    <p>
      <strong>{if @row.configured, do: "QA configured", else: "QA not configured"}</strong>
      · {@row.status}
    </p>
    <p :if={match?({:error, _}, @row.facts)} role="alert">
      QA facts unavailable: {inspect(@row.facts)}
    </p>
    <p :for={job <- @row.pending}>
      Job {job.job_id}: {job.status} · {job.inserted_at}<br />Requested revision: {job.revision ||
        "resolved when the audit starts"}
    </p>
    <p :if={@row.latest}>
      Latest result: {@row.latest.status} · {@row.latest.updated_at}<br />Revision: {@row.latest.revision ||
        "not pinned"}
    </p>
    <p :if={!@row.latest and match?({:ok, _}, @row.facts)}>No recorded QA attempts.</p>
    <button :if={match?({:error, _}, @row.facts)} phx-click="refresh" class="btn-save">Retry loading</button>
    <p>Last fetched target revision: {@row.revision || "unavailable"}</p>
    <p :if={match?({:ok, _}, @row.facts)}>
      {if @row.matched,
        do: "Latest evidence matches the configured command and last fetched target revision.",
        else:
          "No matching latest evidence for the configured command and last fetched target revision."} Remote changes since the last fetch are unverified.
    </p>
    <p>{@row.adoption}</p>
    <p :if={match?({:ok, _}, @row.facts) and !(@row.matched and @row.latest.status == "passed")}>
      Rollout evidence: no latest passed report matches the configured QA command and observed target revision.
    </p>
    """
  end

  attr :row, :map, required: true
  attr :busy, :boolean, required: true
  @spec project_detail(map()) :: Rendered.t()
  defp project_detail(assigns) do
    ~H"""
    <section aria-label="Project QA">
      <h2>{@row.id}</h2><.facts row={@row} />
      <button
        id="qa-start"
        phx-click="start"
        phx-disable-with="Submitting…"
        disabled={@busy or !@row.configured}
        class="btn-dispatch"
      >
        {if @row.latest && @row.latest.status in ["failed", "incomplete"],
          do: "Retry QA",
          else: "Start QA"}
      </button>
      <p>
        Requests use the current remote target. An unchanged revision can be rechecked. Equivalent active requests share a job.
      </p>
      <h3>Configuration and rollout</h3>
      <dl class="insights-summary">
        <div>
          <dt>Full-QA command</dt><dd>{@row.project.qa_command || "Not configured"}</dd>
        </div>
        <div>
          <dt>Effective dispatch checks (retained)</dt><dd>
            {@row.project.check_command || "Not configured"}
          </dd>
        </div>
        <div>
          <dt>Effective landing policy / target</dt><dd>
            {@row.project.landing_policy} / {@row.project.target_branch || "unavailable"}
          </dd>
        </div>
        <div>
          <dt>Landing override</dt><dd>{inspect(@row.override || :none)}</dd>
        </div>
      </dl>
      <p :if={@row.catalog}>Rollout notes: {@row.catalog.notes}</p>
      <details>
        <summary>Persisted registration and effective settings</summary><blockquote>
          {inspect(@row.persisted, pretty: true)}
        </blockquote>
      </details>
      <p>Configuration is not execution evidence. QA does not gate landing or deployment.</p>
      <h3>Recent attempts (up to 10)</h3>
      <p :if={@row.attempts == [] and match?({:ok, _}, @row.facts)}>
        No attempts recorded. Start QA to collect evidence.
      </p>
      <article :for={attempt <- @row.attempts} id={"qa-attempt-" <> attempt.id} class="insights-row">
        <h3>{attempt.status} · {attempt.updated_at}</h3>
        <dl class="insights-summary">
          <div>
            <dt>Exact command</dt><dd>{attempt.command}</dd>
          </div>
          <div>
            <dt>Agent / model</dt><dd>
              {attempt.agent || "unavailable"} / {attempt.model || "unavailable"}
            </dd>
          </div>
          <div>
            <dt>Revision / target</dt><dd>
              {attempt.revision || "not pinned"} / {attempt.target_branch}
            </dd>
          </div>
          <div>
            <dt>Range</dt><dd>
              {attempt.base_sha}..{attempt.revision || "not pinned"} · {attempt.included_landings} included commits
            </dd>
          </div>
        </dl>
        <p :if={
          attempt.command != @row.project.qa_command or attempt.revision != @row.revision or
            attempt.target_branch != @row.project.target_branch
        }>
          Historical evidence: command, target or revision differs from the current observation.
        </p>
        <button class="btn-save" phx-click="evidence" phx-value-id={attempt.id}>Read evidence</button>
      </article>
    </section>
    """
  end
end
