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

  alias Harness.AgentRegistry
  alias Harness.Dashboard.Components
  alias Harness.Dashboard.Transcript
  alias Harness.ProjectRegistry
  alias Harness.Run.Status
  alias Harness.StatusView
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @tick_interval_ms 1_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_tick()

    {:ok,
     socket
     |> assign(:projects, ProjectRegistry.list())
     |> assign(:snapshot, StatusView.snapshot())
     |> assign(:adapters, list_adapters())
     |> assign(:selected_project, nil)
     |> assign(:transcript, "")
     |> assign(:transcript_bytes, 0)
     |> assign(:transcript_events, [])
     |> assign(:agent_kind, nil)
     |> assign(:raw_view, false)
     |> assign(:last_seq, 0)
     |> assign(:events_last_seq, 0)
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

  defp apply_action(socket, :show, %{"run_id" => run_id} = params) do
    socket
    |> maybe_unsubscribe(socket.assigns[:run_id])
    |> subscribe_transcript(run_id)
    |> assign(:run_id, run_id)
    |> assign(:transcript, "")
    |> assign(:transcript_bytes, 0)
    |> assign(:transcript_events, [])
    |> assign(:agent_kind, nil)
    |> assign(:raw_view, raw_view_param?(params))
    |> assign(:last_seq, 0)
    |> assign(:events_last_seq, 0)
    |> backfill_transcript(run_id)
    |> backfill_transcript_events(run_id)
    |> refresh_run_status(run_id)
  end

  @spec raw_view_param?(map()) :: boolean()
  defp raw_view_param?(%{"raw" => value}) when value in ["1", "true"], do: true
  defp raw_view_param?(_), do: false

  @impl Phoenix.LiveView
  def handle_info(:tick, socket) do
    schedule_tick()

    socket =
      socket
      |> assign(:projects, ProjectRegistry.list())
      |> assign(:snapshot, StatusView.snapshot())
      |> assign(:adapters, list_adapters())

    socket =
      case socket.assigns[:run_id] do
        nil -> socket
        run_id -> refresh_run_status(socket, run_id)
      end

    {:noreply, socket}
  end

  # Guard against cross-run bleed: a previously viewed run can still have
  # queued PubSub messages in this LiveView's mailbox after the operator
  # navigates to a different run. Without this guard, those stale chunks
  # append to the newly selected run's transcript pane.
  def handle_info({:harness_transcript, broadcast_run_id, _seq, _chunk}, socket)
      when broadcast_run_id != socket.assigns.run_id do
    {:noreply, socket}
  end

  def handle_info({:harness_transcript, _run_id, seq, _chunk}, socket) when seq <= socket.assigns.last_seq do
    {:noreply, socket}
  end

  def handle_info({:harness_transcript, _run_id, seq, data}, socket) do
    {trimmed, trimmed_bytes} =
      Transcript.append(socket.assigns.transcript, socket.assigns.transcript_bytes, data)

    {:noreply,
     socket
     |> assign(:transcript, trimmed)
     |> assign(:transcript_bytes, trimmed_bytes)
     |> assign(:last_seq, seq)}
  end

  # Cross-run + seq-dedup guards mirror the raw transcript clauses above so a
  # stale delta queued for a previously-viewed run never bleeds into the
  # current pane.
  def handle_info({:harness_transcript_events, broadcast_run_id, _seq, _events}, socket)
      when broadcast_run_id != socket.assigns.run_id do
    {:noreply, socket}
  end

  def handle_info({:harness_transcript_events, _run_id, seq, _events}, socket)
      when seq <= socket.assigns.events_last_seq do
    {:noreply, socket}
  end

  def handle_info({:harness_transcript_events, _run_id, _seq, []}, socket) do
    {:noreply, socket}
  end

  def handle_info({:harness_transcript_events, _run_id, seq, events}, socket) do
    combined = socket.assigns.transcript_events ++ events
    cap = Transcript.event_count_cap()
    bounded = trim_events_to_cap(combined, cap)

    {:noreply,
     socket
     |> assign(:transcript_events, bounded)
     |> assign(:events_last_seq, seq)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @spec trim_events_to_cap(list(), pos_integer()) :: list()
  defp trim_events_to_cap(events, cap) do
    count = length(events)
    if count <= cap, do: events, else: Enum.drop(events, count - cap)
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  @spec list_adapters() :: [%{agent: atom(), module: module(), installed: boolean()}]
  defp list_adapters do
    AgentRegistry.agents()
    |> Enum.map(fn {agent, module} ->
      %{agent: agent, module: module, installed: AgentRegistry.installed?(module)}
    end)
    |> Enum.sort_by(& &1.agent)
  end

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

  # Fetches the buffered transcript + last seq from the run gen_statem and
  # primes the LiveView so a late subscriber does not start from an empty pane.
  # `subscribe_transcript/2` ran first, so any chunks broadcast between subscribe
  # and this call are queued in our mailbox; `handle_info/2`'s seq guard drops
  # the ones already in the snapshot.
  @spec backfill_transcript(Socket.t(), String.t()) :: Socket.t()
  defp backfill_transcript(socket, run_id) do
    case Harness.Run.transcript(run_id) do
      {:ok, %{buffer: buffer, seq: seq}} ->
        socket
        |> assign(:transcript, buffer)
        |> assign(:transcript_bytes, byte_size(buffer))
        |> assign(:last_seq, seq)

      {:error, :not_found} ->
        socket
    end
  end

  # Sibling of backfill_transcript/2 for the parsed-event surface. Pulls the
  # event-list snapshot + the executing adapter's agent_kind + last seq from the
  # run gen_statem so the renderer has stable context across reconnects.
  # `subscribe_transcript/2` ran first, so any event delta broadcast between
  # subscribe and this call is queued in our mailbox AND already folded into the
  # snapshot list; priming `events_last_seq` from the snapshot seq lets the
  # handle_info seq guard drop those already-counted deltas (mirrors
  # backfill_transcript/2's raw-path dedup).
  @spec backfill_transcript_events(Socket.t(), String.t()) :: Socket.t()
  defp backfill_transcript_events(socket, run_id) do
    case Harness.Run.transcript_events(run_id) do
      {:ok, %{events: events, agent_kind: agent_kind, seq: seq}} ->
        socket
        |> assign(:transcript_events, events)
        |> assign(:agent_kind, agent_kind)
        |> assign(:events_last_seq, seq)

      {:error, :not_found} ->
        socket
    end
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
    <p :if={@filtered_runs == []}>No runs in flight or lingering.</p>
    <table :if={@filtered_runs != []}>
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
        <tr :for={entry <- @filtered_runs}>
          <td>{entry.status.task_id}</td>
          <td><.run_link run_id={entry.status.run_id} /></td>
          <td>
            <Components.bucket_badge bucket={entry.bucket} label={to_string(entry.status.state)} />
          </td>
          <td>{entry.status.repair_attempts}</td>
          <td>{verdict_label(entry.status.verdict_status)}</td>
          <td>{entry.detail || ""}</td>
        </tr>
      </tbody>
    </table>

    <h3>Adapters</h3>
    <table>
      <thead>
        <tr>
          <th>Agent</th>
          <th>Module</th>
          <th>Installed</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={adapter <- @adapters}>
          <td><code>{adapter.agent}</code></td>
          <td><code>{inspect(adapter.module)}</code></td>
          <td>{if adapter.installed, do: "yes", else: "no"}</td>
        </tr>
      </tbody>
    </table>

    <div :if={@snapshot.unavailable_agents != []}>
      <h3>Unavailable agents</h3>
      <ul>
        <li :for={{adapter, reason} <- @snapshot.unavailable_agents}>
          <code>{inspect(adapter)}</code> — {inspect(reason)}
        </li>
      </ul>
    </div>
    """
  end

  @spec render_show(map()) :: Rendered.t()
  defp render_show(assigns) do
    ~H"""
    <h1>Run {@run_id}</h1>
    <p><a href="/harness">← All runs</a></p>

    <p :if={@run_status == nil}>
      Run not found (already settled and unregistered, or never started in this BEAM).
    </p>
    <dl :if={@run_status != nil} class="field">
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

    <h2>Transcript</h2>
    <p class="transcript-toggle">
      <a :if={!@raw_view} href={"/harness/runs/#{@run_id}?raw=1"}>view raw stream</a>
      <a :if={@raw_view} href={"/harness/runs/#{@run_id}"}>view parsed turns</a>
    </p>
    <div :if={!@raw_view}>
      <Components.transcript_view events={@transcript_events} agent={@agent_kind} />
    </div>
    <div :if={@raw_view}>
      <p :if={@transcript == ""}>Waiting for output…</p>
      <pre :if={@transcript != ""} class="transcript">{@transcript}</pre>
    </div>
    """
  end

  attr(:projects, :list, required: true)
  attr(:selected, :string, default: nil)

  @spec project_switcher(map()) :: Rendered.t()
  defp project_switcher(assigns) do
    ~H"""
    <select phx-change="select_project">
      <option value="">All projects</option>
      <option :for={project <- @projects} value={project.name} selected={@selected == project.name}>
        {project.name}
      </option>
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
