defmodule Harness.Dashboard.RoadmapLive do
  @moduledoc """
  Fleet task board LiveView (`/harness/roadmap`).

  Turns the former per-project planning rollup into a project-spanning board
  with factual lanes: Pending, Implementing, Reviewing, Landing, Blocked, and
  Done. rmap is authoritative for durable status; live runs and persisted
  results supply execution and landing context. Placement rules live in
  `Harness.Dashboard.TaskBoard` — this view loads those facts, filters by
  project, and invokes existing `Harness.Dispatch` recovery/dispatch contracts.

  ## Cold-path rmap, event-driven runs

  Roadmap reads have no PubSub source, so a slow `:roadmap_tick` re-reads them
  with `sync_checkout: false`. Live run and settle broadcasts (`RunFeed`)
  recompose only the execution facts so an in-flight stage change does not wait
  on the tick. Display reads never fetch origin.

  Actions reuse `Harness.Dispatch` (`task`, `hold`, `resume`, `resume_failed`,
  `rereview`, `reland`). A successful action reloads the board; an error is
  shown and rmap status is left unchanged. Failed and held attempts are badges
  and action state — this view does not compute urgency, health, or priority.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.Components
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.TaskBoard
  alias Harness.Dashboard.TaskBoard.Card
  alias Harness.Dispatch
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.StatusView
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @roadmap_tick_interval_ms 30_000
  @drilldown_timeout_ms 5_000
  @ready_fields ~w(id)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      RunFeed.subscribe()
      schedule_roadmap_tick()
    end

    projects = ProjectRegistry.list()

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:selected_project, nil)
     |> assign(:notice, nil)
     |> assign(:now, DateTime.utc_now(:millisecond))
     |> assign_snapshot(projects)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    selected = blank_to_nil(params["project"])

    {:noreply,
     socket
     |> assign(:selected_project, selected)
     |> assign_lanes()}
  end

  @impl Phoenix.LiveView
  def handle_info(:roadmap_tick, socket) do
    schedule_roadmap_tick()
    projects = ProjectRegistry.list()

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:now, DateTime.utc_now(:millisecond))
     |> assign_snapshot(projects)}
  end

  def handle_info({:harness_run_update, _status}, socket) do
    {:noreply, socket |> assign(:now, DateTime.utc_now(:millisecond)) |> refresh_execution()}
  end

  def handle_info({:harness_run_settled, _status}, socket) do
    {:noreply, socket |> assign(:now, DateTime.utc_now(:millisecond)) |> refresh_execution()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("select_project", %{"project" => project_name}, socket) do
    target =
      case project_name do
        "" -> "/harness/roadmap"
        name -> "/harness/roadmap?project=#{URI.encode_www_form(name)}"
      end

    {:noreply, push_patch(socket, to: target)}
  end

  def handle_event("dispatch_task", %{"project" => project, "task_id" => task_id}, socket) do
    run_board_action(socket, fn -> action(:dispatch, project, task_id, nil) end)
  end

  def handle_event("hold_run", %{"run_id" => run_id}, socket) do
    run_board_action(socket, fn -> action(:hold, nil, nil, run_id) end)
  end

  def handle_event("resume_held", %{"run_id" => run_id}, socket) do
    run_board_action(socket, fn -> action(:resume, nil, nil, run_id) end)
  end

  def handle_event("resume_failed", %{"run_id" => run_id}, socket) do
    run_board_action(socket, fn -> action(:resume_failed, nil, nil, run_id) end)
  end

  def handle_event("rereview_run", %{"run_id" => run_id}, socket) do
    run_board_action(socket, fn -> action(:rereview, nil, nil, run_id) end)
  end

  def handle_event("land_run", %{"run_id" => run_id}, socket) do
    run_board_action(socket, fn -> action(:land, nil, nil, run_id) end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @spec schedule_roadmap_tick() :: reference()
  defp schedule_roadmap_tick, do: Process.send_after(self(), :roadmap_tick, @roadmap_tick_interval_ms)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <h1>Roadmap</h1>
      <span class="count">{length(@projects)} projects</span>
      <form id="roadmap-project-filter" phx-change="select_project">
        <label for="roadmap-project">Project</label>
        <select id="roadmap-project" name="project">
          <option value="" selected={is_nil(@selected_project)}>All projects</option>
          <option
            :for={project <- @projects}
            value={project.name}
            selected={@selected_project == project.name}
          >
            {project.name}
          </option>
        </select>
      </form>
      <a href="/harness">← All runs</a>
    </div>

    <Components.operator_flash notice={@notice} include_persistent={false} />

    <p :for={error <- @load_errors} class="operator-notice" data-kind="error" role="alert">{error}</p>
    <p :if={@record_error} class="operator-notice" data-kind="error" role="alert">{@record_error}</p>
    <p :if={@projects == []}>No projects registered.</p>
    <div :if={@projects != []} class="task-board-bleed">
      <div class="task-board" role="region" aria-label="Fleet task board">
        <section
          :for={lane <- TaskBoard.lanes()}
          class="task-lane"
          data-lane={lane}
          aria-labelledby={"lane-#{lane}"}
        >
          <h2 id={"lane-#{lane}"}>
            {TaskBoard.lane_label(lane)}
            <span class="count">{length(@lanes[lane])}</span>
          </h2>
          <p :if={@lanes[lane] == []} class="task-lane-empty">{empty_lane_line(lane)}</p>
          <.task_card :for={card <- @lanes[lane]} card={card} now={@now} />
        </section>
      </div>
    </div>
    """
  end

  attr(:card, :any, required: true)
  attr(:now, :any, required: true)

  @spec task_card(map()) :: Rendered.t()
  defp task_card(assigns) do
    ~H"""
    <article
      class="task-card"
      data-task-card
      data-project={@card.project_name}
      data-task-id={@card.task_id}
      data-lane={@card.lane}
      data-rmap-status={@card.rmap_status}
      data-run-id={@card.run_id}
    >
      <p class="task-card-id">
        <span>{@card.project_name}</span>
        <span>#{@card.task_id}</span>
      </p>
      <p class="task-card-title">
        <.link :if={@card.run_id} navigate={"/harness/runs/" <> @card.run_id}>
          {@card.title || "—"}
        </.link>
        <span :if={is_nil(@card.run_id)}>{@card.title || "—"}</span>
      </p>
      <dl class="task-card-facts">
        <div>
          <dt>Assignee / model</dt>
          <dd>{fact(@card.assignee)} / {fact(@card.model)}</dd>
        </div>
        <div>
          <dt>rmap</dt>
          <dd>{@card.rmap_status}</dd>
        </div>
        <div>
          <dt>Run stage</dt>
          <dd>{run_stage(@card)}</dd>
        </div>
        <div>
          <dt>Elapsed</dt>
          <dd>{elapsed(@card, @now)}</dd>
        </div>
        <div>
          <dt>Tokens</dt>
          <dd>{tokens(@card)}</dd>
        </div>
      </dl>
      <p :if={@card.dependency} class="task-card-dep" data-dependency={@card.dependency}>
        {dependency_label(@card.dependency)}
      </p>
      <p :if={@card.held? or @card.failed?} class="task-card-badges">
        <span :if={@card.held?} class="bucket bucket-repairing" data-badge="held">held</span>
        <span :if={@card.failed?} class="bucket bucket-red" data-badge="failed">failed</span>
      </p>
      <p :if={@card.run_id} class="task-card-attempt">
        <.link navigate={"/harness/runs/" <> @card.run_id}>attempt {@card.run_id}</.link>
      </p>
      <div :if={@card.actions != []} class="task-card-actions">
        <.card_action :for={action <- @card.actions} action={action} card={@card} />
      </div>
    </article>
    """
  end

  attr(:action, :atom, required: true)
  attr(:card, :any, required: true)

  @spec card_action(map()) :: Rendered.t()
  defp card_action(%{action: :dispatch} = assigns) do
    ~H"""
    <button
      type="button"
      class="btn-dispatch"
      phx-click="dispatch_task"
      phx-value-project={@card.project_name}
      phx-value-task_id={@card.task_id}
      data-confirm={"Dispatch task #{@card.task_id} on #{@card.project_name}?"}
    >
      Dispatch
    </button>
    """
  end

  defp card_action(%{action: :hold} = assigns) do
    ~H"""
    <button
      type="button"
      class="kill-btn"
      phx-click="hold_run"
      phx-value-run_id={@card.run_id}
      data-confirm={"Hold run #{@card.run_id}?"}
    >
      Hold
    </button>
    """
  end

  defp card_action(%{action: :resume} = assigns) do
    ~H"""
    <button
      type="button"
      class="resume-btn"
      phx-click="resume_held"
      phx-value-run_id={@card.run_id}
      data-confirm={"Resume held run #{@card.run_id}?"}
    >
      Resume
    </button>
    """
  end

  defp card_action(%{action: :resume_failed} = assigns) do
    ~H"""
    <button
      type="button"
      class="resume-btn"
      phx-click="resume_failed"
      phx-value-run_id={@card.run_id}
      data-confirm={"Resume failed run #{@card.run_id}?"}
    >
      Resume failed
    </button>
    """
  end

  defp card_action(%{action: :rereview} = assigns) do
    ~H"""
    <button
      type="button"
      class="resume-btn"
      phx-click="rereview_run"
      phx-value-run_id={@card.run_id}
      data-confirm={"Re-review run #{@card.run_id}?"}
    >
      Re-review
    </button>
    """
  end

  defp card_action(%{action: :land} = assigns) do
    ~H"""
    <button
      type="button"
      class="reland-btn"
      phx-click="land_run"
      phx-value-run_id={@card.run_id}
      data-confirm={"Land run #{@card.run_id}?"}
    >
      Land
    </button>
    """
  end

  defp card_action(%{action: :reland} = assigns) do
    ~H"""
    <button
      type="button"
      class="reland-btn"
      phx-click="land_run"
      phx-value-run_id={@card.run_id}
      data-confirm={"Re-land run #{@card.run_id}?"}
    >
      Re-land
    </button>
    """
  end

  @spec assign_snapshot(Socket.t(), [Project.t()]) :: Socket.t()
  defp assign_snapshot(socket, projects) do
    {tasks, ready_ids, errors} = roadmap_facts(projects, Map.get(socket.assigns, :rmap_tasks, %{}))

    socket
    |> assign(:load_errors, errors)
    |> assign(:rmap_tasks, tasks)
    |> assign(:ready_ids, ready_ids)
    |> assign(:live_runs, live_runs())
    |> load_records()
    |> assign_lanes()
  end

  @spec refresh_execution(Socket.t()) :: Socket.t()
  defp refresh_execution(socket) do
    socket
    |> assign(:live_runs, live_runs())
    |> load_records()
    |> assign_lanes()
  end

  @spec assign_lanes(Socket.t()) :: Socket.t()
  defp assign_lanes(socket) do
    lanes =
      [
        projects: socket.assigns.projects,
        tasks: socket.assigns.rmap_tasks,
        ready_ids: socket.assigns.ready_ids,
        live_runs: socket.assigns.live_runs,
        records: socket.assigns.records,
        landable_projects: TaskBoard.landable_project_names(socket.assigns.projects)
      ]
      |> TaskBoard.compose()
      |> TaskBoard.filter_project(socket.assigns.selected_project)

    assign(socket, :lanes, lanes)
  end

  @spec roadmap_facts([Project.t()], map()) :: {map(), TaskBoard.ready_ids(), [String.t()]}
  defp roadmap_facts(projects, previous) do
    listed =
      projects
      |> Task.async_stream(&list_tasks/1, timeout: @drilldown_timeout_ms, on_timeout: :kill_task)
      |> Enum.zip(projects)

    {tasks, errors} =
      Enum.reduce(listed, {%{}, []}, fn
        {{:ok, {:ok, tasks}}, project}, {acc, errors} ->
          {Map.put(acc, project.name, tasks), errors}

        {failure, project}, {acc, errors} ->
          {Map.put(acc, project.name, Map.get(previous, project.name, [])),
           [{project.name, :roadmap, stream_reason(failure)} | errors]}
      end)

    ready_results =
      projects
      |> Task.async_stream(&ready_tasks/1, timeout: @drilldown_timeout_ms, on_timeout: :kill_task)
      |> Enum.zip(projects)

    {ready, errors} =
      Enum.reduce(ready_results, {MapSet.new(), errors}, fn
        {{:ok, {:ok, tasks}}, project}, {acc, errors} ->
          ids = MapSet.new(tasks, &{project.name, to_string(&1["id"])})
          {MapSet.union(acc, ids), errors}

        {failure, project}, {acc, errors} ->
          {acc, [{project.name, :ready, stream_reason(failure)} | errors]}
      end)

    {tasks, ready, summarize_load_errors(Enum.reverse(errors))}
  end

  @spec list_tasks(Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp list_tasks(project) do
    case Application.get_env(:harness, :roadmap_list) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.list(project.name)
    end
  end

  @spec ready_tasks(Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp ready_tasks(project) do
    case Application.get_env(:harness, :roadmap_ready) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.ready(project: project, fields: @ready_fields, sync_checkout: false)
    end
  end

  @spec live_runs() :: [Status.t()]
  defp live_runs do
    case Application.get_env(:harness, :task_board_live_runs) do
      fun when is_function(fun, 0) -> fun.()
      _other -> Enum.map(StatusView.live_runs(), & &1.status)
    end
  end

  @spec records() :: {:ok, [LogRecord.t()]} | {:error, term()}
  defp records do
    case Application.get_env(:harness, :task_board_records) do
      fun when is_function(fun, 0) -> {:ok, fun.()}
      _other -> ResultStore.list_run_records()
    end
  end

  @spec load_records(Socket.t()) :: Socket.t()
  defp load_records(socket) do
    case records() do
      {:ok, records} ->
        socket |> assign(:records, records) |> assign(:record_error, nil)

      {:error, reason} ->
        socket
        |> assign(:records, Map.get(socket.assigns, :records, []))
        |> assign(:record_error, "Run results unavailable: #{inspect(reason)}")
    end
  end

  @spec run_board_action(Socket.t(), (-> {:ok, String.t()} | {:error, String.t()})) :: {:noreply, Socket.t()}
  defp run_board_action(socket, fun) do
    case fun.() do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:notice, {:ok, message})
         |> assign(:now, DateTime.utc_now(:millisecond))
         |> assign_snapshot(socket.assigns.projects)}

      {:error, message} ->
        {:noreply, assign(socket, :notice, {:error, message})}
    end
  end

  @spec action(atom(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp action(name, project, task_id, run_id) do
    case Application.get_env(:harness, :task_board_action) do
      fun when is_function(fun, 4) -> fun.(name, project, task_id, run_id)
      _other -> dispatch_action(name, project, task_id, run_id)
    end
  end

  @spec dispatch_action(atom(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp dispatch_action(:dispatch, project, task_id, _run_id) do
    format_result(Dispatch.task(project, task_id), "Dispatched task #{task_id}.", "Dispatch failed")
  end

  defp dispatch_action(:hold, _project, _task_id, run_id) do
    format_result(Dispatch.hold(run_id), "Held run #{run_id}.", "Hold failed")
  end

  defp dispatch_action(:resume, _project, _task_id, run_id) do
    format_result(Dispatch.resume(run_id), "Resumed run #{run_id}.", "Resume failed")
  end

  defp dispatch_action(:resume_failed, _project, _task_id, run_id) do
    format_result(Dispatch.resume_failed(run_id), "Resume failed queued for #{run_id}.", "Resume failed")
  end

  defp dispatch_action(:rereview, _project, _task_id, run_id) do
    format_result(Dispatch.rereview(run_id), "Re-review queued for #{run_id}.", "Re-review failed")
  end

  defp dispatch_action(:land, _project, _task_id, run_id) do
    format_result(Dispatch.reland(run_id), "Landing enqueued for #{run_id}.", "Land failed")
  end

  @spec format_result(term(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp format_result({:ok, _value}, ok, _error), do: {:ok, ok}
  defp format_result({:error, reason}, _ok, error), do: {:error, "#{error}: #{inspect(reason)}"}

  @spec empty_lane_line(TaskBoard.lane()) :: String.t()
  defp empty_lane_line(:pending), do: "No pending tasks."
  defp empty_lane_line(:implementing), do: "No implementing tasks."
  defp empty_lane_line(:reviewing), do: "No reviewing tasks."
  defp empty_lane_line(:landing), do: "No landing tasks."
  defp empty_lane_line(:blocked), do: "No blocked tasks."
  defp empty_lane_line(:done), do: "No recent done tasks."

  @spec dependency_label(:ready | :waiting | :unknown) :: String.t()
  defp dependency_label(:ready), do: "Dependencies ready"
  defp dependency_label(:waiting), do: "Waiting on dependencies"
  defp dependency_label(:unknown), do: "Dependencies unavailable"

  @spec fact(String.t() | nil) :: String.t()
  defp fact(nil), do: "—"
  defp fact(""), do: "—"
  defp fact(value), do: value

  @spec run_stage(Card.t()) :: String.t()
  defp run_stage(%Card{run_state: nil}), do: "—"
  defp run_stage(%Card{run_state: state}), do: Atom.to_string(state)

  @spec elapsed(Card.t(), DateTime.t()) :: String.t()
  defp elapsed(%Card{status: %Status{state: state, duration_ms: duration} = status}, now)
       when state in [:done, :failed] and is_integer(duration) do
    Components.elapsed_label(%{status | started_at: nil}, now)
  end

  defp elapsed(%Card{status: %Status{} = status}, now), do: Components.elapsed_label(status, now)
  defp elapsed(_card, _now), do: "—"

  @spec tokens(Card.t()) :: String.t()
  defp tokens(%Card{token_total: total}) when is_integer(total) do
    total |> Integer.to_string() |> Components.delimit()
  end

  defp tokens(_card), do: "—"

  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @spec stream_reason(term()) :: term()
  defp stream_reason({:ok, {:error, reason}}), do: reason
  defp stream_reason({:ok, reason}), do: reason
  defp stream_reason({:exit, :kill}), do: :timeout
  defp stream_reason({:exit, reason}), do: reason
  defp stream_reason(reason), do: reason

  @spec summarize_load_errors([{String.t(), :roadmap | :ready, term()}]) :: [String.t()]
  defp summarize_load_errors(errors) do
    errors
    |> Enum.group_by(fn {_name, kind, reason} -> {kind, reason} end)
    |> Enum.sort_by(fn {{kind, reason}, _items} -> {kind, inspect(reason)} end)
    |> Enum.map(fn {{kind, reason}, items} ->
      names = items |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(", ")
      "#{names}: #{load_error_kind(kind)} (#{format_reason(reason)})"
    end)
  end

  @spec load_error_kind(:roadmap | :ready) :: String.t()
  defp load_error_kind(:roadmap), do: "roadmap unavailable"
  defp load_error_kind(:ready), do: "dispatch readiness unavailable"

  @spec format_reason(term()) :: String.t()
  defp format_reason(:roadmap_not_found), do: "no local roadmap"
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
