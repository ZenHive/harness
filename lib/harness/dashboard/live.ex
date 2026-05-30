defmodule Harness.Dashboard.Live do
  @moduledoc """
  The harness LiveView (Task 50).

  Renders two views off the same module:

    * `:index` (`/harness`) — project switcher, per-bucket run counts, and two
      `Phoenix.LiveView` streams: "Active runs" (in-flight / repairing runs) and
      "Run history" (settled runs). One row per run with state and verdict.
    * `:show` (`/harness/runs/:run_id`) — drill-down on a single run with its
      live `Harness.Run.Status` fields and a streaming transcript pane fed by
      `Harness.Dashboard.Transcript` (Pass 2) broadcasts.

  ## Event-driven, not polled

  The run tables are driven by `Harness.Dashboard.RunFeed` — a fleet-wide
  PubSub feed the `Harness.Run` gen_statem broadcasts on each lifecycle change.
  `{:harness_run_update, status}` patches the active-run stream in place (keyed
  by run id); `{:harness_run_settled, status}` removes the row from the active
  stream and prepends it to history. The persisted history is read from the
  store **once at mount** (and re-filtered in memory on a project switch) — no
  per-tick disk scan.

  Sidebar metadata (registered projects, adapters, unavailable/quota agents) has
  no event source, so a slow **5s `:meta_tick`** keeps it fresh. That tick does
  no disk I/O and never touches the run streams.

  An operator can kill an in-flight run from either view via a confirm-gated
  "Kill run" button (`Task 94`); the `"kill_run"` event routes through
  `Harness.Run.cancel/1` (idempotent — settles the run `:failed`). The resulting
  `:harness_run_settled` broadcast transitions the row/detail to its settled
  state.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.AgentRegistry
  alias Harness.Dashboard.Components
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.StatusView
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @meta_tick_interval_ms 5_000

  # Mirror StatusView's history cap so the history stream's DOM size stays
  # bounded over a long-lived session.
  @history_limit 200

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      RunFeed.subscribe()
      schedule_meta_tick()
    end

    # The single disk read: seed sidebar + history at mount. Active runs and the
    # history/active stream contents are populated by apply_action(:index) from
    # in-memory state (live_runs/0) + the history_all assign — no further reads.
    snapshot = StatusView.snapshot()

    {:ok,
     socket
     |> assign(:projects, ProjectRegistry.list())
     |> assign(:adapters, list_adapters())
     |> assign(:unavailable, snapshot.unavailable_agents)
     |> assign(:selected_project, nil)
     |> assign(:counts, bucket_counts(snapshot))
     |> assign(:history_all, snapshot.history)
     |> assign(:active_empty?, true)
     |> assign(:history_empty?, snapshot.history == [])
     |> assign(:transcript, "")
     |> assign(:transcript_bytes, 0)
     |> assign(:transcript_events, [])
     |> assign(:agent_kind, nil)
     |> assign(:raw_view, false)
     |> assign(:last_seq, 0)
     |> assign(:events_last_seq, 0)
     |> assign(:run_status, nil)
     |> assign(:run_id, nil)
     |> stream_configure(:active_runs, dom_id: &"active-#{&1.status.run_id}")
     |> stream_configure(:history, dom_id: &"hist-#{&1.status.run_id}")
     |> stream(:active_runs, [])
     |> stream(:history, [])}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @spec apply_action(Socket.t(), atom(), map()) :: Socket.t()
  defp apply_action(socket, :index, params) do
    selected = Map.get(params, "project")
    runs = StatusView.live_runs()
    active = runs |> reject_terminal() |> filter_runs(selected)
    history = filter_runs(socket.assigns.history_all, selected)

    socket
    |> maybe_unsubscribe(socket.assigns[:run_id])
    |> assign(:run_id, nil)
    |> assign(:run_status, nil)
    |> assign(:selected_project, selected)
    |> assign(:counts, bucket_counts(%{runs: runs}))
    |> assign(:active_empty?, active == [])
    |> assign(:history_empty?, history == [])
    |> stream(:active_runs, active, reset: true)
    |> stream(:history, history, reset: true)
  end

  defp apply_action(socket, :show, %{"run_id" => run_id} = params) do
    socket =
      socket
      |> maybe_unsubscribe(socket.assigns[:run_id])
      |> assign(:run_id, run_id)
      |> assign(:transcript, "")
      |> assign(:transcript_bytes, 0)
      |> assign(:transcript_events, [])
      |> assign(:agent_kind, nil)
      |> assign(:raw_view, raw_view_param?(params))
      |> assign(:last_seq, 0)
      |> assign(:events_last_seq, 0)

    # Resolve the source once: a live run streams over PubSub; a settled run is
    # replayed from its persisted LogRecord so the drill-down survives a restart.
    case Harness.Run.status(run_id) do
      {:ok, %Status{} = status} ->
        socket
        |> assign(:run_status, status)
        |> subscribe_transcript(run_id)
        |> backfill_transcript(run_id)
        |> backfill_transcript_events(run_id)

      {:error, :not_found} ->
        load_historical(socket, run_id)
    end
  end

  @spec raw_view_param?(map()) :: boolean()
  defp raw_view_param?(%{"raw" => value}) when value in ["1", "true"], do: true
  defp raw_view_param?(_), do: false

  @impl Phoenix.LiveView
  def handle_info(:meta_tick, socket) do
    schedule_meta_tick()

    # Sidebar-only refresh: registered projects, adapters, and unavailable/quota
    # agents. All in-memory — no snapshot, no store read, no run-stream touch.
    socket =
      socket
      |> assign(:projects, ProjectRegistry.list())
      |> assign(:adapters, list_adapters())
      |> assign(:unavailable, AgentRegistry.list_unavailable())

    # On the index, also recompute the in-memory fleet counts + active-empty
    # flag. Lifecycle events drive these, but a settled run's terminal-linger
    # expiry (~5s) deregisters it with no broadcast — without this, the topbar
    # tallies keep counting the gone run until the next fleet event. live_runs/0
    # is in-memory (no disk), and recompute_active only assigns — no stream patch.
    socket = if socket.assigns.live_action == :index, do: recompute_active(socket), else: socket

    {:noreply, socket}
  end

  # Fleet run-lifecycle feed (RunFeed). On the index view these patch the run
  # streams; on the show view they refresh the focused run's status. A run that
  # belongs to a different view/run_id is ignored.
  def handle_info({:harness_run_update, %Status{} = status}, socket) do
    {:noreply, apply_run_update(socket, status)}
  end

  def handle_info({:harness_run_settled, %Status{} = status}, socket) do
    {:noreply, apply_run_settled(socket, status)}
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

  # ── Run-lifecycle application ─────────────────────────────────────────────

  # On the show view, a lifecycle message only matters when it's the focused
  # run — refresh its status (live transitions + settle freeze).
  @spec apply_run_update(Socket.t(), Status.t()) :: Socket.t()
  defp apply_run_update(%{assigns: %{live_action: :show}} = socket, %Status{} = status) do
    refresh_focused_run(socket, status)
  end

  defp apply_run_update(socket, %Status{} = status) do
    entry = StatusView.run_entry_for(status)
    socket = recompute_active(socket)

    if passes_filter?(entry, socket.assigns.selected_project) do
      stream_insert(socket, :active_runs, entry)
    else
      socket
    end
  end

  @spec apply_run_settled(Socket.t(), Status.t()) :: Socket.t()
  defp apply_run_settled(%{assigns: %{live_action: :show}} = socket, %Status{} = status) do
    refresh_focused_run(socket, status)
  end

  defp apply_run_settled(socket, %Status{} = status) do
    entry = StatusView.run_entry_for(status)
    history_all = prepend_history(entry, socket.assigns.history_all)
    selected = socket.assigns.selected_project

    socket =
      socket
      |> stream_delete(:active_runs, entry)
      |> assign(:history_all, history_all)
      |> recompute_active()
      |> assign(:history_empty?, filter_runs(history_all, selected) == [])

    if passes_filter?(entry, selected) do
      stream_insert(socket, :history, entry, at: 0, limit: @history_limit)
    else
      socket
    end
  end

  @spec refresh_focused_run(Socket.t(), Status.t()) :: Socket.t()
  defp refresh_focused_run(socket, %Status{run_id: run_id} = status) do
    if socket.assigns.run_id == run_id do
      assign(socket, :run_status, status)
    else
      socket
    end
  end

  # Recompute the fleet counts + active-empty flag from the in-memory live runs.
  # counts are fleet-wide (every project — matches the pre-stream behavior);
  # active_empty? reflects the *filtered* active table the operator sees.
  @spec recompute_active(Socket.t()) :: Socket.t()
  defp recompute_active(socket) do
    runs = StatusView.live_runs()
    active = runs |> reject_terminal() |> filter_runs(socket.assigns.selected_project)

    socket
    |> assign(:counts, bucket_counts(%{runs: runs}))
    |> assign(:active_empty?, active == [])
  end

  @spec prepend_history(StatusView.run_entry(), [StatusView.run_entry()]) :: [StatusView.run_entry()]
  defp prepend_history(entry, history_all) do
    deduped = Enum.reject(history_all, &(&1.status.run_id == entry.status.run_id))
    Enum.take([entry | deduped], @history_limit)
  end

  @spec passes_filter?(StatusView.run_entry(), String.t() | nil) :: boolean()
  defp passes_filter?(entry, selected), do: filter_runs([entry], selected) != []

  # The active table shows only non-terminal runs; a settled run lives in
  # history. Lingering settled runs (still registered for ~5s) are excluded here.
  @spec reject_terminal([StatusView.run_entry()]) :: [StatusView.run_entry()]
  defp reject_terminal(runs) do
    Enum.reject(runs, fn entry -> entry.status.state in [:done, :failed] end)
  end

  @spec trim_events_to_cap(list(), pos_integer()) :: list()
  defp trim_events_to_cap(events, cap) do
    count = length(events)
    if count <= cap, do: events, else: Enum.drop(events, count - cap)
  end

  @spec schedule_meta_tick() :: reference()
  defp schedule_meta_tick, do: Process.send_after(self(), :meta_tick, @meta_tick_interval_ms)

  @spec list_adapters() :: [%{agent: atom(), module: module(), installed: boolean()}]
  defp list_adapters do
    AgentRegistry.agents()
    |> Enum.map(fn {agent, module} ->
      %{agent: agent, module: module, installed: AgentRegistry.installed?(module)}
    end)
    |> Enum.sort_by(& &1.agent)
  end

  # Settled run: no live gen_statem to subscribe to. Rebuild the status snapshot
  # and replay the transcript from the persisted LogRecord so the drill-down
  # survives a BEAM restart. An empty/errored store lookup leaves run_status nil
  # (the render_show "Run not found" copy).
  @spec load_historical(Socket.t(), String.t()) :: Socket.t()
  defp load_historical(socket, run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{} = record | _]} ->
        socket
        |> assign(:run_status, Status.from_log_record(record))
        |> replay_transcript(record)

      _ ->
        assign(socket, :run_status, nil)
    end
  end

  # Mirrors backfill_transcript/2 + backfill_transcript_events/2 for a settled
  # run, sourcing both panes from the record's captured output instead of the
  # live gen_statem. The raw pane is always populated; the parsed pane only when
  # the executing agent can be resolved to a parser kind.
  @spec replay_transcript(Socket.t(), LogRecord.t()) :: Socket.t()
  defp replay_transcript(socket, %LogRecord{agent_output: output} = record) do
    socket =
      socket
      |> assign(:transcript, output)
      |> assign(:transcript_bytes, byte_size(output))

    case agent_kind_for(record) do
      nil ->
        socket

      agent_kind ->
        socket
        |> assign(:transcript_events, parse_events(agent_kind, output))
        |> assign(:agent_kind, agent_kind)
    end
  end

  @spec parse_events(Parser.agent_kind(), binary()) :: [Parser.event()]
  defp parse_events(agent_kind, output) do
    state = Parser.init_state(agent_kind)
    {events, state} = Parser.append(agent_kind, output, state)
    {final, _state} = Parser.finalize(agent_kind, state)
    events ++ final
  end

  # LogRecord.agent carries the agent atom on the batch path; for a direct run
  # it can be nil, so fall back to reverse-mapping the adapter module against
  # AgentRegistry.agents/0. Returns nil when neither resolves to a known parser
  # kind (raw pane still renders).
  @spec agent_kind_for(LogRecord.t()) :: Parser.agent_kind() | nil
  defp agent_kind_for(%LogRecord{agent: agent, adapter: adapter}) do
    agents = AgentRegistry.agents()
    known = Enum.map(agents, fn {a, _module} -> a end)

    if agent in known, do: agent, else: reverse_lookup_agent(agents, adapter)
  end

  @spec reverse_lookup_agent(%{atom() => module()}, module()) :: atom() | nil
  defp reverse_lookup_agent(agents, adapter) do
    Enum.find_value(agents, fn {agent, module} -> if module == adapter, do: agent end)
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
    <p :if={@active_empty?}>No runs in flight or lingering.</p>
    <.run_table id="active-runs" rows={@streams.active_runs} />

    <h2>Run history</h2>
    <p :if={@history_empty?}>No persisted runs.</p>
    <.run_table id="run-history" rows={@streams.history} />

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

    <div :if={@unavailable != []}>
      <h3>Unavailable agents</h3>
      <ul>
        <li :for={{adapter, reason} <- @unavailable}>
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

    <p :if={killable?(@run_status)}>
      <.kill_button run_id={@run_id} />
    </p>

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
    <form phx-change="select_project">
      <select name="project">
        <option value="">All projects</option>
        <option :for={project <- @projects} value={project.name} selected={@selected == project.name}>
          {project.name}
        </option>
      </select>
    </form>
    """
  end

  attr(:id, :string, required: true)
  attr(:rows, :any, required: true)

  # Shared by the "Active runs" and "Run history" tables. `rows` is a
  # `Phoenix.LiveView` stream; the `<tbody>` carries `phx-update="stream"` and a
  # stable id so inserts/deletes patch individual rows. Settled rows render no
  # kill action — `killable?/1` returns false for terminal states — so the same
  # markup serves both live and historical entries.
  @spec run_table(map()) :: Rendered.t()
  defp run_table(assigns) do
    ~H"""
    <table>
      <thead>
        <tr>
          <th>Task</th>
          <th>Run</th>
          <th>State</th>
          <th>Attempts</th>
          <th>Verdict</th>
          <th>Detail</th>
          <th>Action</th>
        </tr>
      </thead>
      <tbody id={@id} phx-update="stream">
        <tr :for={{dom_id, entry} <- @rows} id={dom_id}>
          <td>{entry.status.task_id}</td>
          <td><.run_link run_id={entry.status.run_id} /></td>
          <td>
            <Components.bucket_badge bucket={entry.bucket} label={to_string(entry.status.state)} />
          </td>
          <td>{entry.status.repair_attempts}</td>
          <td>{verdict_label(entry.status.verdict_status)}</td>
          <td>{entry.detail || ""}</td>
          <td>
            <.kill_button :if={killable?(entry.status)} run_id={entry.status.run_id} />
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr(:run_id, :string, required: true)

  @spec run_link(map()) :: Rendered.t()
  defp run_link(assigns) do
    ~H"""
    <a href={"/harness/runs/#{@run_id}"}>{@run_id}</a>
    """
  end

  attr(:run_id, :string, required: true)

  # Confirm-gated kill affordance shared by the index row and the run-detail
  # view. A misfire settles the run :failed, so the `data-confirm` prompt is
  # mandatory; the click routes to the `"kill_run"` handle_event.
  @spec kill_button(map()) :: Rendered.t()
  defp kill_button(assigns) do
    ~H"""
    <button
      type="button"
      class="kill-btn"
      phx-click="kill_run"
      phx-value-run_id={@run_id}
      data-confirm={"Kill run #{@run_id}? This settles it :failed."}
    >
      Kill run
    </button>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("select_project", %{"project" => project_name}, socket) do
    target =
      case project_name do
        "" -> "/harness"
        name -> "/harness?project=#{URI.encode_www_form(name)}"
      end

    {:noreply, push_patch(socket, to: target)}
  end

  def handle_event("kill_run", %{"run_id" => run_id}, socket) do
    # Idempotent — settles the run :failed. The resulting :harness_run_settled
    # broadcast transitions the index streams and (if focused) the detail view.
    :ok = Harness.Run.cancel(run_id)
    {:noreply, socket}
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
    Enum.filter(runs, &(&1.status.project_name == project_name))
  end

  @doc false
  @spec verdict_label(:pass | :fail | nil) :: String.t()
  def verdict_label(:pass), do: "pass"
  def verdict_label(:fail), do: "fail"
  def verdict_label(nil), do: "—"

  @doc false
  @spec killable?(Status.t() | nil) :: boolean()
  def killable?(%Status{state: state}) when state in [:done, :failed], do: false
  def killable?(%Status{}), do: true
  def killable?(nil), do: false
end
