defmodule Harness.Dashboard.Live do
  @moduledoc """
  The harness LiveView (Task 50).

  Renders three views off the same module:

    * `:index` (`/harness`) — project switcher, per-bucket run counts, and
      grouped active-run table; one row per run with state and verdict.
    * `:show` (`/harness/runs/:run_id`) — drill-down on a single run with its
      live `Harness.Run.Status` fields and a streaming transcript pane fed by
      `Harness.Dashboard.Transcript` (Pass 2) broadcasts.

  Live state is sourced from `Harness.StatusView.snapshot/0` for the run
  buckets and `Harness.ProjectRegistry.list/0` for the project switcher. A 1s
  tick keeps the snapshot fresh; per-run transcript chunks arrive over
  `Phoenix.PubSub` and append to the LiveView's bounded transcript buffer.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Dashboard.Transcript
  alias Harness.ProjectRegistry
  alias Harness.Run.Status
  alias Harness.StatusView
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @tick_interval_ms 1_000
  @transcript_buffer_bytes 200 * 1024

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_tick()

    {:ok,
     socket
     |> assign(:projects, ProjectRegistry.list())
     |> assign(:snapshot, StatusView.snapshot())
     |> assign(:selected_project, nil)
     |> assign(:transcript, "")
     |> assign(:transcript_bytes, 0)
     |> assign(:run_status, nil)
     |> assign(:run_id, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @spec apply_action(Socket.t(), atom(), map()) :: Socket.t()
  defp apply_action(socket, :index, params) do
    selected = Map.get(params, "project")

    socket
    |> assign(:selected_project, selected)
    |> maybe_unsubscribe(socket.assigns[:run_id])
    |> assign(:run_id, nil)
    |> assign(:run_status, nil)
  end

  defp apply_action(socket, :show, %{"run_id" => run_id}) do
    socket
    |> maybe_unsubscribe(socket.assigns[:run_id])
    |> subscribe_transcript(run_id)
    |> assign(:run_id, run_id)
    |> assign(:transcript, "")
    |> assign(:transcript_bytes, 0)
    |> refresh_run_status(run_id)
  end

  @impl Phoenix.LiveView
  def handle_info(:tick, socket) do
    schedule_tick()

    socket =
      socket
      |> assign(:projects, ProjectRegistry.list())
      |> assign(:snapshot, StatusView.snapshot())

    socket =
      case socket.assigns[:run_id] do
        nil -> socket
        run_id -> refresh_run_status(socket, run_id)
      end

    {:noreply, socket}
  end

  def handle_info({:harness_transcript, _run_id, data}, socket) do
    chunk = IO.iodata_to_binary(data)
    new_bytes = socket.assigns.transcript_bytes + byte_size(chunk)
    combined = socket.assigns.transcript <> chunk
    {trimmed, trimmed_bytes} = trim_transcript(combined, new_bytes)

    {:noreply,
     socket
     |> assign(:transcript, trimmed)
     |> assign(:transcript_bytes, trimmed_bytes)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  @spec refresh_run_status(Socket.t(), String.t()) :: Socket.t()
  defp refresh_run_status(socket, run_id) do
    status =
      case Harness.Run.status(run_id) do
        {:ok, %Status{} = status} -> status
        {:error, :not_found} -> nil
      end

    assign(socket, :run_status, status)
  end

  @spec subscribe_transcript(Socket.t(), String.t()) :: Socket.t()
  defp subscribe_transcript(socket, run_id) do
    if connected?(socket) do
      Transcript.subscribe(run_id)
    end

    socket
  end

  @spec maybe_unsubscribe(Socket.t(), String.t() | nil) :: Socket.t()
  defp maybe_unsubscribe(socket, nil), do: socket

  defp maybe_unsubscribe(socket, run_id) do
    if connected?(socket) do
      Transcript.unsubscribe(run_id)
    end

    socket
  end

  @doc false
  @spec trim_transcript(binary(), non_neg_integer()) :: {binary(), non_neg_integer()}
  def trim_transcript(buffer, bytes) when bytes <= @transcript_buffer_bytes, do: {buffer, bytes}

  def trim_transcript(buffer, _bytes) do
    target = @transcript_buffer_bytes
    size = byte_size(buffer)
    start = size - target
    trimmed = binary_part(buffer, start, target)
    {trimmed, byte_size(trimmed)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    case assigns.live_action do
      :show -> render_show(assigns)
      _ -> render_index(assigns)
    end
  end

  @spec render_index(map()) :: Rendered.t()
  defp render_index(assigns) do
    counts = bucket_counts(assigns.snapshot)
    filtered_runs = filter_runs(assigns.snapshot.runs, assigns.selected_project)
    assigns = assign(assigns, counts: counts, filtered_runs: filtered_runs)

    ~H"""
    <h1>Harness Dashboard</h1>
    <div class="topbar">
      <strong>Project:</strong>
      <.project_switcher projects={@projects} selected={@selected_project} />
      <span class="count">{@counts.in_flight} in flight</span>
      <span class="count">{@counts.repairing} repairing</span>
      <span class="count">{@counts.green} green</span>
      <span class="count">{@counts.red} red</span>
      <a href="/harness/oban">Open Oban Web →</a>
    </div>

    <h2>Active runs</h2>
    <%= if @filtered_runs == [] do %>
      <p>No runs in flight or lingering.</p>
    <% else %>
      <table>
        <thead>
          <tr>
            <th>Task</th>
            <th>Run</th>
            <th>State</th>
            <th>Attempts</th>
            <th>Verdict</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          <%= for entry <- @filtered_runs do %>
            <tr>
              <td>{entry.status.task_id}</td>
              <td><.run_link run_id={entry.status.run_id} /></td>
              <td><span class={"bucket bucket-#{entry.bucket}"}>{entry.status.state}</span></td>
              <td>{entry.status.repair_attempts}</td>
              <td>{verdict_label(entry.status.verdict_status)}</td>
              <td>{entry.detail || ""}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>

    <%= if @snapshot.unavailable_agents != [] do %>
      <h3>Unavailable agents</h3>
      <ul>
        <%= for {adapter, reason} <- @snapshot.unavailable_agents do %>
          <li><code>{inspect(adapter)}</code> — {inspect(reason)}</li>
        <% end %>
      </ul>
    <% end %>
    """
  end

  @spec render_show(map()) :: Rendered.t()
  defp render_show(assigns) do
    ~H"""
    <h1>Run {@run_id}</h1>
    <p><a href="/harness">← All runs</a></p>

    <%= if @run_status == nil do %>
      <p>Run not found (already settled and unregistered, or never started in this BEAM).</p>
    <% else %>
      <dl class="field">
        <dt>Task</dt>
        <dd>{@run_status.task_id}</dd>
        <dt>State</dt>
        <dd>{@run_status.state}</dd>
        <dt>Repair attempts</dt>
        <dd>{@run_status.repair_attempts}</dd>
        <dt>Verdict</dt>
        <dd>{verdict_label(@run_status.verdict_status)}</dd>
        <dt>Agent kind</dt>
        <dd>{inspect(@run_status.agent_kind)}</dd>
        <dt>Agent OS pid</dt>
        <dd>{@run_status.agent_os_pid || "—"}</dd>
        <dt>Reason</dt>
        <dd>{inspect(@run_status.reason)}</dd>
        <dt>Worktree path</dt>
        <dd>{@run_status.worktree_path || "—"}</dd>
      </dl>
    <% end %>

    <h2>Transcript</h2>
    <%= if @transcript == "" do %>
      <p>Waiting for output…</p>
    <% else %>
      <pre class="transcript">{@transcript}</pre>
    <% end %>
    """
  end

  attr(:projects, :list, required: true)
  attr(:selected, :string, default: nil)

  @spec project_switcher(map()) :: Rendered.t()
  defp project_switcher(assigns) do
    ~H"""
    <select phx-change="select_project">
      <option value="">All projects</option>
      <%= for project <- @projects do %>
        <option value={project.name} selected={@selected == project.name}>{project.name}</option>
      <% end %>
    </select>
    """
  end

  attr(:run_id, :string, required: true)

  @spec run_link(map()) :: Rendered.t()
  defp run_link(assigns) do
    ~H"""
    <a href={"/harness/runs/#{@run_id}"}>{@run_id}</a>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("select_project", %{"value" => project_name}, socket) do
    target =
      case project_name do
        "" -> "/harness"
        name -> "/harness?project=#{URI.encode_www_form(name)}"
      end

    {:noreply, push_patch(socket, to: target)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @doc false
  @spec bucket_counts(StatusView.t()) :: %{required(StatusView.bucket()) => non_neg_integer()}
  def bucket_counts(%{runs: runs}) do
    Enum.reduce(runs, %{in_flight: 0, repairing: 0, green: 0, red: 0}, fn entry, acc ->
      Map.update(acc, entry.bucket, 1, &(&1 + 1))
    end)
  end

  @doc false
  @spec filter_runs([StatusView.run_entry()], String.t() | nil) :: [StatusView.run_entry()]
  def filter_runs(runs, nil), do: runs

  def filter_runs(runs, project_name) do
    Enum.filter(runs, fn entry ->
      String.starts_with?(entry.status.run_id, "#{project_name}/") or
        Map.get(entry, :project_name) == project_name
    end)
  end

  @doc false
  @spec verdict_label(:pass | :fail | nil) :: String.t()
  def verdict_label(:pass), do: "pass"
  def verdict_label(:fail), do: "fail"
  def verdict_label(nil), do: "—"
end
