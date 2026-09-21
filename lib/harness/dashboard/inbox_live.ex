defmodule Harness.Dashboard.InboxLive do
  @moduledoc "Operator Inbox and its live navigation count."
  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.Inbox
  alias Harness.Dashboard.RunFeed
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, session, socket) do
    if connected?(socket) do
      RunFeed.subscribe()
      schedule_tick()
    end

    socket =
      socket
      |> assign(
        compact: session["compact"] == true,
        rows: %{},
        selected_project: nil,
        count: 0,
        count_label: "—",
        coverage_errors: [],
        coverage_notices: [],
        loading: true,
        error: nil,
        notice: nil,
        operation_error: nil,
        busy: nil,
        submitted: MapSet.new(),
        projects: []
      )
      |> stream(:actions, [])

    {:ok, if(connected?(socket), do: refresh(socket), else: socket)}
  end

  @impl true
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:selected_project, params["project"]) |> show_rows()}
  end

  @impl true
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(:inbox_tick, socket) do
    schedule_tick()
    {:noreply, refresh(socket)}
  end

  def handle_info({event, _status}, socket) when event in [:harness_run_update, :harness_run_settled],
    do: {:noreply, refresh(socket)}

  def handle_info(:inbox_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  @spec handle_async(term(), term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_async(_name, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:facts, {:ok, {:ok, %{rows: rows} = snapshot}}, socket) when is_list(rows) do
    errors = Map.get(snapshot, :coverage_errors, [])

    {:noreply,
     socket
     |> assign(
       rows: Map.new(rows, &{&1.id, &1}),
       coverage_errors: errors,
       loading: false,
       error: nil,
       submitted: MapSet.intersection(socket.assigns.submitted, MapSet.new(rows, & &1.id)),
       projects: snapshot_projects(rows, errors)
     )
     |> show_rows()}
  end

  def handle_async(:facts, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(loading: false, error: inspect(reason)) |> show_rows()}
  end

  def handle_async(:facts, {:exit, reason}, socket) do
    {:noreply, socket |> assign(loading: false, error: inspect(reason)) |> show_rows()}
  end

  def handle_async(:facts, result, socket) do
    {:noreply, socket |> assign(loading: false, error: inspect(result)) |> show_rows()}
  end

  def handle_async(:operation, {:ok, {:ok, result}}, socket) do
    id = socket.assigns.busy
    Phoenix.PubSub.broadcast(Harness.PubSub, RunFeed.topic(), :inbox_changed)

    {:noreply,
     socket
     |> assign(
       busy: nil,
       notice:
         "Request accepted#{if result[:run_id], do: " for run #{result.run_id}", else: ""}. Current facts will refresh.",
       submitted: MapSet.put(socket.assigns.submitted, id)
     )
     |> show_rows()
     |> refresh()}
  end

  def handle_async(:operation, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(busy: nil, operation_error: inspect(reason), notice: nil) |> show_rows()}
  end

  def handle_async(:operation, {:exit, reason}, socket) do
    {:noreply, socket |> assign(busy: nil, operation_error: inspect(reason), notice: nil) |> show_rows()}
  end

  def handle_async(:operation, result, socket) do
    {:noreply, socket |> assign(busy: nil, operation_error: inspect(result), notice: nil) |> show_rows()}
  end

  @impl true
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("select_project", %{"project" => project}, socket) do
    target =
      case project do
        "" -> "/harness/inbox"
        name -> "/harness/inbox?project=#{URI.encode_www_form(name)}"
      end

    {:noreply, push_patch(socket, to: target)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("act", %{"id" => id, "action" => action}, socket) do
    row = socket.assigns.rows[id]

    if row && is_nil(socket.assigns.error) && is_nil(socket.assigns.busy) &&
         not MapSet.member?(socket.assigns.submitted, id) &&
         socket.assigns.selected_project in [nil, "", row.project] do
      {:noreply,
       socket
       |> assign(busy: id, notice: nil, operation_error: nil)
       |> show_rows()
       |> start_async(:operation, fn -> Inbox.perform(row, action) end)}
    else
      {:noreply, assign(socket, :notice, "Action failed: stale or already submitted action. Refresh the Inbox.")}
    end
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{compact: true} = assigns) do
    ~H"""
    <a href="/harness/inbox" id="inbox-navigation">
      Inbox <span class="count" style="margin-left: 0.35em;">{@count_label}</span>
    </a>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="topbar">
      <h1>Action Inbox</h1>
      <span id="inbox-count" class="count" aria-live="polite">{@count_label} unresolved</span>
      <form id="inbox-project-filter" phx-change="select_project">
        <label for="inbox-project">Project</label>
        <select id="inbox-project" name="project">
          <option value="" selected={@selected_project in [nil, ""]}>All projects</option>
          <option
            :for={project <- Enum.uniq([@selected_project | @projects])}
            :if={project not in [nil, ""]}
            value={project}
            selected={@selected_project == project}
          >
            {project}
          </option>
        </select>
      </form>
      <button class="resume-btn" style="min-height: 44px;" phx-click="refresh">Refresh</button>
    </div>
    <p>
      Current approvals, held runs, recovery and landing actions. Each row names the exact attempt.
    </p>
    <p :if={@loading} role="status">Loading current actions…</p>
    <div :if={@error} role="alert">
      <p>Inbox unavailable. Actions are disabled until current facts load. Use Refresh to retry.</p>
      <details>
        <summary>Load error details</summary><pre style="white-space: pre-wrap; overflow-wrap: anywhere;">{@error}</pre>
      </details>
    </div>
    <div :if={@operation_error} role="alert">
      <p>Action failed. Review the error and the run, then refresh current facts before retrying.</p>
      <details>
        <summary>Action error details</summary><pre style="white-space: pre-wrap; overflow-wrap: anywhere;">{@operation_error}</pre>
      </details>
    </div>
    <p :if={@notice} role="status">{@notice}</p>
    <p :for={notice <- @coverage_notices} class="operator-notice" data-kind="error" role="alert">
      {notice}
    </p>
    <p
      :if={not @loading and is_nil(@error) and @count == 0 and @coverage_notices == []}
      class="empty-state"
    >
      No unresolved actions in this project scope.
    </p>
    <div id="inbox-actions" phx-update="stream">
      <article
        :for={{dom_id, row} <- @streams.actions}
        id={dom_id}
        class="task-card"
        data-project={row.project}
        data-run-id={row.run_id}
      >
        <h2>{row.project} · Task {row.task_id}</h2>
        <p :if={row.run_id}>
          <a href={"/harness/runs/" <> URI.encode_www_form(row.run_id)}>Run {row.run_id}</a>
        </p>
        <p :if={row.pending}>Pending approval · {DateTime.to_iso8601(row.pending.parked_at)}</p>
        <p :if={row.context[:title]}>{row.context.title}</p>
        <p :if={row.context[:state]}>State: {row.context.state}</p>
        <p :if={row.context[:hold_reason]}>Hold: {row.context.hold_reason}</p>
        <p :if={row.context[:reason]} style="overflow-wrap: anywhere;">
          {inspect(row.context.reason)}
        </p>
        <p :if={row.pending}>Adapter: {row.pending.adapter |> Module.split() |> List.last()}</p>
        <p :if={row.pending && row.pending.opts[:dispatch_decision]} style="overflow-wrap: anywhere;">
          {inspect(row.pending.opts[:dispatch_decision])}
        </p>
        <div class="task-card-actions">
          <button
            :for={action <- row.actions}
            type="button"
            class="resume-btn"
            style="min-height: 44px;"
            phx-click="act"
            phx-value-id={row.id}
            phx-value-action={action}
            phx-disable-with="Submitting…"
            disabled={not is_nil(@busy) or not is_nil(@error)}
          >
            {Inbox.label(action)}
          </button>
        </div>
      </article>
    </div>
    """
  end

  @spec refresh(Socket.t()) :: Socket.t()
  defp refresh(socket), do: start_async(socket, :facts, fn -> Inbox.load() end)

  @spec show_rows(Socket.t()) :: Socket.t()
  defp show_rows(socket) do
    selected = socket.assigns.selected_project

    rows =
      socket.assigns.rows
      |> Map.values()
      |> Enum.reject(&MapSet.member?(socket.assigns.submitted, &1.id))
      |> Enum.filter(&(selected in [nil, "", &1.project]))
      |> Enum.sort_by(&{&1.project, &1.task_id, &1.id})

    notices =
      socket.assigns.coverage_errors
      |> Enum.filter(&(selected in [nil, "", elem(&1, 0)]))
      |> Enum.map(&Inbox.format_coverage_error/1)

    count = length(rows)

    socket
    |> assign(
      count: count,
      coverage_notices: notices,
      count_label: count_label(socket.assigns.loading, socket.assigns.error, notices != [], count)
    )
    |> stream(:actions, rows, reset: true)
  end

  @spec snapshot_projects([map()], [{String.t(), term()}]) :: [String.t()]
  defp snapshot_projects(rows, errors) do
    (Enum.map(rows, & &1.project) ++ Enum.map(errors, &elem(&1, 0)))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec count_label(boolean(), term(), boolean(), non_neg_integer()) :: String.t() | non_neg_integer()
  defp count_label(true, _error, _incomplete, _count), do: "—"
  defp count_label(_loading, error, _incomplete, _count) when not is_nil(error), do: "—"
  defp count_label(_loading, _error, true, 0), do: "—"
  defp count_label(_loading, _error, _incomplete, count), do: count

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :inbox_tick, 5_000)
end
