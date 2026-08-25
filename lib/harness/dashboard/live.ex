defmodule Harness.Dashboard.Live do
  @moduledoc """
  The harness LiveView (Task 50).

  Renders two views off the same module:

    * `:index` (`/harness`) — project switcher, per-state run counts plus a
      mechanical in-flight audit count on the same strip (OpsFeed
      `audit_started` without a matching `audit_settled` for that project/range;
      audits never ride `Run.Status`), and two `Phoenix.LiveView` streams:
      "Active runs" (live lifecycle states) and "Run history" (settled runs).
      One row per run with state and verdict.
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

  Sidebar metadata (registered projects) has no event source, so a slow
  **5s `:meta_tick`** keeps it fresh. That tick does no disk I/O and never
  touches the run streams. Adapter install/enable/quota state lives on the
  Settings page (`Harness.Dashboard.SettingsLive`), not here.

  An operator can kill an in-flight run from either view via a confirm-gated
  "Kill run" button (`Task 94`); the `"kill_run"` event routes through
  `Harness.Run.cancel/1` (idempotent — settles the run `:failed`). The resulting
  `:harness_run_settled` broadcast transitions the row/detail to its settled
  state.

  ## Recovery affordances (Task 204)

  Settled runs carry two confirm-gated recovery buttons, each surfaced only when
  the run's state permits it — harness offers, the operator chooses (agent-gate:
  no auto-classification of which recovery applies). The same `.row-actions`
  group renders on the index row and under Run info on the run-detail page:

    * **Resume / Escalate** — on a `:failed` run (`resumable?/1`). Re-dispatches the
      run's roadmap task on a NEW run that branches off the retained
      `harness/<run-id>` branch (prior commits are the starting point) with the
      failure report injected into the prompt. "Resume" reuses the original agent;
      "Escalate" routes to the capability-recommended agent. Both go through
      `Harness.Dispatch.resume_failed/2` (escalate? = the `escalate` flag).
    * **Re-land** — on a run whose land-train hit its cap and left the task `blocked`
      (`relandable?/2`, gated on `Harness.Dashboard.RoadmapSummary.blocked?/3`).
      Re-enqueues the landing job (`Harness.Dispatch.reland/1` → `Harness.Lander.enqueue/1`);
      the branch is already reviewer-approved, so this spends **zero agent tokens**.
    * **Land** — on an approved-but-unlanded run of a `landing_policy: :manual`
      project that has a `target_branch` configured (`landable?/3`). Manual-policy
      projects never auto-enqueue a land, so an approved run otherwise sits with
      only a Delete action; this is the manual merge trigger. Same backend as
      Re-land (`Harness.Lander.enqueue/1`, zero agent tokens) — the gate differs:
      Re-land recovers a blocked auto-train, Land is the first land of a manual
      project. The button is hidden until `target_branch` is set, so it appears
      exactly where landing can succeed (`landable_project_names/1`).

  Both events set the `:notice` assign (`{kind, msg}`), rendered by
  `Harness.Dashboard.Components.operator_flash/1`. Stream refresh rides the
  normal `RunFeed` broadcast.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.AgentRegistry
  alias Harness.Dashboard.Components
  alias Harness.Dashboard.OpsFeed
  alias Harness.Dashboard.OpsFeed.Op
  alias Harness.Dashboard.RoadmapSummary
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.Run.TranscriptSnapshot
  alias Harness.RunDiff
  alias Harness.StatusView
  alias Harness.TokenUsage.GrokSession
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @meta_tick_interval_ms 5_000

  # Roadmap rollups (open-task counts) come from a cold-path `rmap list` per
  # project and have no PubSub source, so a slow tick refreshes them — far slower
  # than meta_tick since landing is minutes-paced. Run mergedness is not derived
  # here; it is the persisted `Status.landed_sha` fact.
  @roadmap_tick_interval_ms 30_000

  # Mirror StatusView's history cap so the history stream's DOM size stays
  # bounded over a long-lived session.
  @history_limit 200

  # Audit + land ops are infrequent (minutes-paced) and each settled audit op can
  # carry a (capped) transcript, so the ops panel keeps a small bounded list in a
  # plain assign rather than a stream. Newest-first, truncated to this many rows.
  @ops_limit 40

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      RunFeed.subscribe()
      OpsFeed.subscribe()
      schedule_meta_tick()
      schedule_roadmap_tick()
    end

    projects = ProjectRegistry.list()

    # The single disk read: seed sidebar + history at mount. Active runs and the
    # history/active stream contents are populated by apply_action(:index) from
    # in-memory state (live_runs/0) + the history_all assign — no further reads.
    roadmap = RoadmapSummary.for_projects(projects)
    snapshot = StatusView.snapshot()
    history = reconcile_history_landed(snapshot.history, projects, roadmap)

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:roadmap, roadmap)
     |> assign(:ops, [])
     |> assign(:audit_flights, [])
     |> assign(:now, DateTime.utc_now(:millisecond))
     |> assign(:show_landed, false)
     |> assign(:notice, nil)
     |> assign(:selected_project, nil)
     |> assign(:counts, bucket_counts(snapshot))
     |> assign(:history_all, history)
     |> assign(:live_runs_once, snapshot.runs)
     |> assign(:active_empty?, true)
     |> assign(:history_empty?, history == [])
     |> assign(:transcript, "")
     |> assign(:transcript_bytes, 0)
     |> assign(:transcript_events, [])
     |> assign(:agent_kind, nil)
     |> assign(:raw_view, false)
     |> assign(:last_seq, 0)
     |> assign(:events_last_seq, 0)
     |> assign(:last_transcript_at, nil)
     |> assign(:run_status, nil)
     |> assign(:review_record, nil)
     |> assign(:run_diff, nil)
     |> assign(:run_id, nil)
     |> assign(:task_item, nil)
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
    {runs, socket} = take_live_runs(socket)
    active = runs |> reject_terminal() |> filter_runs(selected)

    socket
    |> maybe_unsubscribe(socket.assigns[:run_id])
    |> assign(:run_id, nil)
    |> assign(:run_status, nil)
    |> assign(:review_record, nil)
    |> assign(:selected_project, selected)
    |> assign(:counts, bucket_counts(%{runs: runs}))
    |> assign(:active_empty?, active == [])
    |> stream(:active_runs, active, reset: true)
    |> restream_history()
  end

  defp apply_action(socket, :show, %{"run_id" => run_id} = params) do
    socket =
      socket
      |> maybe_unsubscribe(socket.assigns[:run_id])
      |> assign(:live_runs_once, nil)
      |> assign(:run_id, run_id)
      |> assign(:transcript, "")
      |> assign(:transcript_bytes, 0)
      |> assign(:transcript_events, [])
      |> assign(:agent_kind, nil)
      |> assign(:raw_view, raw_view_param?(params))
      |> assign(:last_seq, 0)
      |> assign(:events_last_seq, 0)
      |> assign(:last_transcript_at, nil)
      |> assign(:run_diff, nil)
      |> assign(:review_record, load_review_record(run_id))

    # Resolve the source once: a live run streams over PubSub; a settled run is
    # replayed from its persisted LogRecord so the drill-down survives a restart.
    socket =
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

    socket
    |> assign_task_item()
    |> maybe_load_diff()
  end

  # Live read of the focused run's roadmap task (title/body/criteria/score/markers)
  # so the show view can render *what* the agent is working on, not just the task
  # id. Fetched once here on `:show` — the run's task_id is stable for its
  # lifetime, so the live-update path (`refresh_focused_run/2`) never refetches and
  # the per-tick refreshes reuse the cached `:task_item`. Reads degrade to `nil`
  # (no Task section) when the project/task can't be resolved.
  @spec assign_task_item(Socket.t()) :: Socket.t()
  defp assign_task_item(%{assigns: %{run_status: %Status{} = status}} = socket) do
    assign(socket, :task_item, load_task_item(status.task_id, status.project_name))
  end

  defp assign_task_item(socket), do: assign(socket, :task_item, nil)

  # Resolve a roadmap task to its `%Item{}` via the read-only `Roadmap.ingest/2`,
  # or `nil` on any miss: blank id/project, an unregistered project, or a task that
  # drifted out of the roadmap (edited/deleted) since dispatch. Never raises — a
  # roadmap read must not crash the run page.
  @doc false
  @spec load_task_item(String.t() | nil, String.t() | nil) :: Item.t() | nil
  def load_task_item(task_id, project_name)
      when is_binary(task_id) and task_id != "" and is_binary(project_name) and project_name != "" do
    with {:ok, %Project{} = project} <- ProjectRegistry.lookup(project_name),
         {:ok, %Item{} = item} <- Roadmap.ingest({:id, task_id}, project: project) do
      item
    else
      _ -> nil
    end
  end

  def load_task_item(_task_id, _project_name), do: nil

  @spec take_live_runs(Socket.t()) :: {[StatusView.run_entry()], Socket.t()}
  defp take_live_runs(%{assigns: %{live_runs_once: runs}} = socket) when is_list(runs) do
    {runs, assign(socket, :live_runs_once, nil)}
  end

  defp take_live_runs(socket), do: {StatusView.live_runs(), socket}

  # A terminal run (live-but-lingering or replayed from the store) has its work
  # committed on the `harness/<run_id>` branch — read the real diff from git on
  # demand. In-flight and not-found runs carry no committed diff; the show view
  # renders the live edited-files list instead.
  @spec maybe_load_diff(Socket.t()) :: Socket.t()
  defp maybe_load_diff(%{assigns: %{run_status: %Status{state: state} = status}} = socket)
       when state in [:done, :failed] do
    assign(socket, :run_diff, RunDiff.for_run(status.run_id, status.project_name))
  end

  defp maybe_load_diff(socket), do: socket

  @spec raw_view_param?(map()) :: boolean()
  defp raw_view_param?(%{"raw" => value}) when value in ["1", "true"], do: true
  defp raw_view_param?(_), do: false

  @doc false
  # The in-progress change signal for a live run: file paths the agent has
  # touched, harvested from its file-editing tool calls in the parsed transcript.
  # Keys on a string-keyed `file_path`/`path` tool argument rather than a tool-name
  # allowlist, so Claude Edit/Write/MultiEdit and Cursor (whose tool input is
  # string-keyed) surface. Codex's `command_execution` carries a shell command
  # under an atom key, not a file path, so it does not surface here. First-seen
  # order, deduped. `@doc false` def (not defp) so the helper is unit-testable.
  @spec live_edited_files([Parser.event()]) :: [String.t()]
  def live_edited_files(events) do
    events
    |> Components.edited_file_stats()
    |> Enum.map(& &1.path)
  end

  @impl Phoenix.LiveView
  def handle_info(:meta_tick, socket) do
    schedule_meta_tick()

    # Sidebar-only refresh: registered projects. In-memory — no snapshot, no
    # store read, no run-stream touch. (Adapter/agent state lives on Settings.)
    socket = assign(socket, :projects, ProjectRegistry.list())
    socket = assign(socket, :now, DateTime.utc_now(:millisecond))

    # On the index, also recompute the in-memory fleet counts + active-empty
    # flag. Lifecycle events drive these, but a settled run's terminal-linger
    # expiry (~5s) deregisters it with no broadcast — without this, the topbar
    # tallies keep counting the gone run until the next fleet event. live_runs/0
    # is in-memory (no disk), and recompute_active only assigns — no stream patch.
    socket = if socket.assigns.live_action == :index, do: recompute_active(socket), else: socket

    {:noreply, socket}
  end

  # Cold-path roadmap refresh: re-read each project's open-task rollup (no
  # PubSub source for it). On the index, also re-stream history so row actions
  # that depend on blocked-task state stay current.
  def handle_info(:roadmap_tick, socket) do
    schedule_roadmap_tick()
    roadmap = RoadmapSummary.for_projects(socket.assigns.projects)

    socket =
      socket
      |> assign(:roadmap, roadmap)
      |> assign(:history_all, reconcile_history_landed(socket.assigns.history_all, socket.assigns.projects, roadmap))

    socket = if socket.assigns.live_action == :index, do: restream_history(socket), else: socket
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

  # Audit + land lifecycle (OpsFeed). Separate Oban workers that never reach the
  # run gen_statem, so they ride their own topic into a dedicated ops panel —
  # newest-first, bounded. Prepend on every transition; no run-stream touch.
  # Audit started/settled also maintain the in-flight audit count on the index
  # strip (session-scoped, matching the ops panel's ephemeral contract).
  def handle_info({:harness_op, %Op{} = op}, socket) do
    socket =
      socket
      |> assign(:ops, Enum.take([op | socket.assigns.ops], @ops_limit))
      |> assign(:audit_flights, track_audit_flights(socket.assigns.audit_flights, op))
      |> maybe_mark_history_landed(op)

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
     |> assign(:last_seq, seq)
     |> stamp_transcript_arrival()}
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
     |> assign(:events_last_seq, seq)
     |> stamp_transcript_arrival()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @spec stamp_transcript_arrival(Socket.t()) :: Socket.t()
  defp stamp_transcript_arrival(socket) do
    assign(socket, :last_transcript_at, DateTime.utc_now(:millisecond))
  end

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
    socket = refresh_focused_run(socket, status)

    if socket.assigns.run_id == status.run_id do
      assign(socket, :review_record, load_review_record(status.run_id))
    else
      socket
    end
  end

  defp apply_run_settled(socket, %Status{} = status) do
    entry = settled_entry(status)
    history_all = prepend_history(entry, socket.assigns.history_all)

    socket =
      socket
      |> stream_delete(:active_runs, entry)
      |> assign(:history_all, history_all)
      |> recompute_active()

    socket = assign(socket, :history_empty?, history_rows(socket) == [])

    # A just-settled run has no landed_sha yet, so it belongs in the default
    # unmerged view; show_in_history?/2 still honors the project filter.
    if show_in_history?(entry, socket) do
      stream_insert(socket, :history, entry, at: 0, limit: @history_limit)
    else
      socket
    end
  end

  @spec settled_entry(Status.t()) :: StatusView.run_entry()
  defp settled_entry(%Status{} = status) do
    concerns =
      case load_review_record(status.run_id) do
        %LogRecord{review_concerns: concerns} -> concerns
        nil -> []
      end

    status |> StatusView.run_entry_for() |> Map.put(:review_concerns, concerns)
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
    Enum.take([entry | prune_history(history_all, entry.status.run_id)], @history_limit)
  end

  # Drops every history entry for `run_id` — shared by prepend_history/2 (dedup
  # before prepending the latest) and the "delete_run" handler (operator discard).
  @doc false
  @spec prune_history([StatusView.run_entry()], String.t()) :: [StatusView.run_entry()]
  def prune_history(history_all, run_id) do
    Enum.reject(history_all, &(&1.status.run_id == run_id))
  end

  @doc false
  @spec mark_history_landed([StatusView.run_entry()], String.t(), String.t()) :: [StatusView.run_entry()]
  def mark_history_landed(history_all, run_id, sha) do
    Enum.map(history_all, fn
      %{status: %Status{run_id: ^run_id} = status} = entry -> %{entry | status: %{status | landed_sha: sha}}
      entry -> entry
    end)
  end

  @doc false
  @spec reconcile_history_landed(
          [StatusView.run_entry()],
          [Project.t()],
          RoadmapSummary.summaries(),
          ResultStore.store()
        ) :: [StatusView.run_entry()]
  def reconcile_history_landed(history_all, projects, roadmap, store \\ ResultStore.configured()) do
    projects_by_name = Map.new(projects, &{&1.name, &1})

    Enum.map(history_all, &reconcile_history_entry(&1, projects_by_name, roadmap, store))
  end

  @spec reconcile_history_entry(
          StatusView.run_entry(),
          %{optional(String.t()) => Project.t()},
          RoadmapSummary.summaries(),
          ResultStore.store()
        ) :: StatusView.run_entry()
  defp reconcile_history_entry(
         %{status: %Status{landed_sha: nil, state: state} = status} = entry,
         projects_by_name,
         roadmap,
         store
       )
       when state in [:done, :failed] do
    project = Map.get(projects_by_name, status.project_name)
    shipped_in = RoadmapSummary.landed_sha(roadmap, status.project_name, status.task_id)

    case ResultStore.reconcile_landed_sha(status.run_id, shipped_in, project, store) do
      {:ok, sha} -> %{entry | status: %{status | landed_sha: sha}}
      :unchanged -> entry
    end
  end

  defp reconcile_history_entry(entry, _projects_by_name, _roadmap, _store), do: entry

  @spec maybe_mark_history_landed(Socket.t(), Op.t()) :: Socket.t()
  defp maybe_mark_history_landed(socket, %Op{kind: :land, stage: :landed, run_id: run_id, sha: sha})
       when is_binary(run_id) and is_binary(sha) do
    socket
    |> assign(:history_all, mark_history_landed(socket.assigns.history_all, run_id, sha))
    |> maybe_restream_history()
  end

  defp maybe_mark_history_landed(socket, %Op{}), do: socket

  @spec maybe_restream_history(Socket.t()) :: Socket.t()
  defp maybe_restream_history(%{assigns: %{live_action: :index}} = socket), do: restream_history(socket)
  defp maybe_restream_history(socket), do: socket

  @spec passes_filter?(StatusView.run_entry(), String.t() | nil) :: boolean()
  defp passes_filter?(entry, selected), do: filter_runs([entry], selected) != []

  # The history rows the operator sees: project-filtered, then (unless the landed
  # view is toggled on) reduced to the unmerged set — runs with no landed_sha.
  @spec history_rows(Socket.t()) :: [StatusView.run_entry()]
  defp history_rows(socket) do
    socket.assigns.history_all
    |> filter_runs(socket.assigns.selected_project)
    |> filter_landed(socket.assigns.show_landed)
  end

  @spec restream_history(Socket.t()) :: Socket.t()
  defp restream_history(socket) do
    rows = history_rows(socket)

    socket
    |> assign(:history_empty?, rows == [])
    |> stream(:history, rows, reset: true)
  end

  @spec filter_landed([StatusView.run_entry()], boolean()) :: [StatusView.run_entry()]
  defp filter_landed(runs, true), do: runs

  defp filter_landed(runs, false), do: Enum.reject(runs, &landed_entry?/1)

  @spec show_in_history?(StatusView.run_entry(), Socket.t()) :: boolean()
  defp show_in_history?(entry, socket) do
    passes_filter?(entry, socket.assigns.selected_project) and
      (socket.assigns.show_landed or not landed_entry?(entry))
  end

  @doc false
  @spec landed_entry?(StatusView.run_entry()) :: boolean()
  def landed_entry?(%{status: %Status{landed_sha: sha}}), do: sha != nil

  # Count of landed (merged) runs hidden from the unmerged default view, shown on
  # the toggle so mergedness is legible at a glance without expanding the view.
  @spec landed_toggle_label([StatusView.run_entry()], String.t() | nil) :: String.t()
  defp landed_toggle_label(history_all, selected) do
    hidden = history_all |> filter_runs(selected) |> Enum.count(&landed_entry?/1)
    "Show landed runs (#{hidden})"
  end

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

  @spec schedule_roadmap_tick() :: reference()
  defp schedule_roadmap_tick, do: Process.send_after(self(), :roadmap_tick, @roadmap_tick_interval_ms)

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
        |> assign(:review_record, record)
        |> replay_transcript(record)

      _ ->
        assign(socket, :run_status, nil)
    end
  end

  @spec load_review_record(String.t()) :: LogRecord.t() | nil
  defp load_review_record(run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{} = record | _]} -> record
      _ -> nil
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
        |> assign(:transcript_events, Parser.replay(agent_kind, output))
        |> assign(:agent_kind, agent_kind)
    end
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
      {:ok, %TranscriptSnapshot{events: events, agent_kind: agent_kind, seq: seq}} ->
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
    <h1>Harness fleet</h1>
    <div class="topbar">
      <strong>Project:</strong>
      <.project_switcher projects={@projects} selected={@selected_project} />
      <a href="/harness/kpi">Agent KPIs →</a>
      <a href="/harness/oban">Open Oban Web →</a>
    </div>

    <div class="kpi-strip fleet-counts" aria-label="Run state counts">
      <div
        :for={{state, count} <- count_tiles(@counts)}
        class={["kpi-stat", count == 0 && "is-zero"]}
      >
        <span class="kpi-stat-num">{count}</span>
        <span class="kpi-stat-label">{bucket_label(state)}</span>
      </div>
      <div
        class={["kpi-stat", "fleet-audit", @audit_flights == [] && "is-zero"]}
        aria-label="Audits in flight"
        data-audits-in-flight={length(@audit_flights)}
      >
        <span class="kpi-stat-num">{length(@audit_flights)}</span>
        <span class="kpi-stat-label">audit</span>
      </div>
    </div>

    <Components.operator_flash notice={@notice} include_persistent={false} />

    <h2>Active runs</h2>
    <p :if={@active_empty?} class="empty-state">{active_empty_line(@selected_project)}</p>
    <.run_table
      id="active-runs"
      rows={@streams.active_runs}
      summaries={@roadmap}
      landable_projects={landable_project_names(@projects)}
      caption="Active runs"
      empty={@active_empty?}
    />

    <h2>
      Run history <span :if={!@show_landed}> — unmerged only</span>
    </h2>
    <p class="history-toggle">
      <button type="button" class="history-toggle-btn" phx-click="toggle_landed">
        {if @show_landed,
          do: "Hide landed runs",
          else: landed_toggle_label(@history_all, @selected_project)}
      </button>
    </p>
    <p :if={@history_empty?} class="empty-state">
      {history_empty_line(@selected_project, @history_all)}
    </p>
    <.run_table
      id="run-history"
      rows={@streams.history}
      summaries={@roadmap}
      landable_projects={landable_project_names(@projects)}
      caption="Run history"
      empty={@history_empty?}
    />

    <.ops_panel ops={@ops} />
    """
  end

  # The two index empty-states report the fleet's condition, not a list's
  # length. Both are scope-aware because both tables honor the project filter:
  # "the fleet is idle" would be false while another project is mid-run.
  @spec active_empty_line(String.t() | nil) :: String.t()
  defp active_empty_line(nil), do: "The fleet is idle — no run is executing."
  defp active_empty_line(project), do: "#{project} is idle — no run is executing."

  # Keyed on the real condition rather than on the landed toggle: with nothing
  # settled in scope, "every settled run has landed" is only vacuously true.
  @spec history_empty_line(String.t() | nil, [StatusView.run_entry()]) :: String.t()
  defp history_empty_line(selected, history_all) do
    history_empty_reason(selected, filter_runs(history_all, selected))
  end

  @spec history_empty_reason(String.t() | nil, [StatusView.run_entry()]) :: String.t()
  defp history_empty_reason(nil, []), do: "No run has settled yet — the result ledger is empty."

  defp history_empty_reason(project, []), do: "No run has settled yet for #{project} — the result ledger holds none."

  defp history_empty_reason(_selected, _settled), do: "Every settled run has landed — none is waiting to merge."

  @spec render_show(map()) :: Rendered.t()
  defp render_show(assigns) do
    ~H"""
    <h1>Run {@run_id}</h1>
    <p><a href="/harness">← All runs</a></p>
    <Components.operator_flash notice={@notice} include_persistent={false} />

    <nav :if={@run_status != nil} class="run-detail-nav">
      <a href="#run-info">Run info</a>
      <a :if={@task_item != nil} href="#run-task">Task</a>
      <a :if={review_testimony_present?(@review_record)} href="#review-testimony">Review</a>
      <a href="#run-diff">Changed files</a>
      <a href="#run-transcript">Transcript</a>
    </nav>

    <p :if={@run_status == nil}>
      Run not found (already settled and unregistered, or never started in this BEAM).
    </p>
    <div :if={@run_status != nil} id="run-info" class="run-section">
      <dl class="field">
        <dt>Task</dt>
        <dd>{@run_status.task_id}</dd>
        <dt>State</dt>
        <dd><Components.stage_stepper state={@run_status.state} /></dd>
        <dt>Verdict</dt>
        <dd>{verdict_label(@run_status.review_verdict)}</dd>
        <dt :if={@run_status.review_warning?}>Reviewer warning</dt>
        <dd :if={@run_status.review_warning?}>approved with recorded checks/concerns</dd>
        <dt>Agent</dt>
        <dd class={run_agent_class(:implementer, @run_status)}>
          <span
            :if={active_agent_role(@run_status) == :implementer}
            class="cf-live-dot"
            aria-hidden="true"
          ></span>
          {agent_label(@agent_kind, @run_status.agent)}
        </dd>
        <dt :if={@run_status.reviewer_adapter}>Reviewer</dt>
        <dd :if={@run_status.reviewer_adapter} class={run_agent_class(:reviewer, @run_status)}>
          <span
            :if={active_agent_role(@run_status) in [:reviewer, :recovery_review]}
            class="cf-live-dot"
            aria-hidden="true"
          ></span>
          {reviewer_detail_label(@run_status)}
        </dd>
        <dt :if={@run_status.recovery_adapter}>Recovery</dt>
        <dd :if={@run_status.recovery_adapter} class={run_agent_class(:recovery, @run_status)}>
          <span
            :if={active_agent_role(@run_status) == :recovery}
            class="cf-live-dot"
            aria-hidden="true"
          ></span>
          {agent_label(@run_status.recovery_adapter, nil)}
        </dd>
        <dt>Model</dt>
        <dd>{model_label(@agent_kind, @run_status.model, @transcript)}</dd>
        <dt>Tokens</dt>
        <dd>{token_label(stage_token_agent_kind(@run_status, @agent_kind), @transcript)}</dd>
        <Components.run_timing status={@run_status} now={@now} />
      </dl>
      <.run_failure
        :if={@run_status.state == :failed and @run_status.reason != nil}
        status={@run_status}
      />
      <.row_actions
        status={@run_status}
        summaries={@roadmap}
        landable_projects={landable_project_names(@projects)}
      />
      <details class="run-internals">
        <summary>Run internals</summary>
        <dl class="field">
          <dt>Verdict</dt>
          <dd>{verdict_label(@run_status.review_verdict)}</dd>
          <dt>Elapsed</dt>
          <dd data-run-internals-elapsed>{Components.elapsed_label(@run_status, @now)}</dd>
          <dt>Worktree path</dt>
          <dd>{@run_status.worktree_path || "—"}</dd>
          <dt>Agent OS pid</dt>
          <dd>{@run_status.agent_os_pid || "—"}</dd>
        </dl>
      </details>
    </div>

    <.review_testimony :if={review_testimony_present?(@review_record)} record={@review_record} />

    <.task_section :if={@task_item != nil} item={@task_item} />

    <div :if={@run_status != nil} id="run-diff" class="run-section">
      <h2>Changed files</h2>
      <Components.edited_files_live
        :if={killable?(@run_status)}
        files={Components.edited_file_stats(@transcript_events)}
      />
      <Components.run_diff_view :if={not killable?(@run_status)} diff={@run_diff} />
    </div>

    <h2 id="run-transcript" class="run-section">Transcript</h2>
    <p class="transcript-toggle">
      <a :if={!@raw_view} href={"/harness/runs/#{@run_id}?raw=1"}>view raw stream</a>
      <a :if={@raw_view} href={"/harness/runs/#{@run_id}"}>view parsed turns</a>
    </p>
    <div :if={!@raw_view}>
      <Components.transcript_chrome
        events={@transcript_events}
        agent={@agent_kind}
        last_event_at={@last_transcript_at}
        now={@now}
        live={killable?(@run_status)}
      />
      <Components.transcript_view events={@transcript_events} agent={@agent_kind} />
    </div>
    <div :if={@raw_view}>
      <p :if={@transcript == ""}>Waiting for output…</p>
      <pre :if={@transcript != ""} class="transcript">{@transcript}</pre>
    </div>
    """
  end

  attr(:item, :map, required: true)

  # The roadmap task the focused run is working on: title + score + markers as a
  # `.field` block (matching the run metadata above it), the acceptance criteria
  # as a list, and the full body in a collapsed `<details>` so it never dominates
  # the page. Each block is conditional — a task with no score / no markers / no
  # criteria / no body renders only what it has.
  @spec task_section(map()) :: Rendered.t()
  defp task_section(assigns) do
    ~H"""
    <div id="run-task" class="task-details run-section">
      <h2>Task</h2>
      <dl class="field">
        <dt>Title</dt>
        <dd>{@item.title}</dd>
        <dt :if={@item.d != nil}>Score (D)</dt>
        <dd :if={@item.d != nil}>{@item.d}</dd>
        <dt :if={@item.markers != []}>Markers</dt>
        <dd :if={@item.markers != []}>
          <span :for={marker <- @item.markers} class="config-pill">{to_string(marker)}</span>
        </dd>
      </dl>
      <div :if={@item.acceptance_criteria != []}>
        <h3 class="task-subhead">Acceptance criteria</h3>
        <ul class="task-criteria">
          <li :for={criterion <- @item.acceptance_criteria}>{criterion}</li>
        </ul>
      </div>
      <details :if={@item.body not in [nil, ""]} class="task-body">
        <summary>Body</summary>
        <pre>{@item.body}</pre>
      </details>
    </div>
    """
  end

  attr(:projects, :list, required: true)
  attr(:selected, :string, default: nil)

  @spec project_switcher(map()) :: Rendered.t()
  defp project_switcher(assigns) do
    ~H"""
    <form id="project-switcher-form" phx-change="select_project">
      <select name="project" aria-label="Project">
        <option value="">All projects</option>
        <option :for={project <- @projects} value={project.name} selected={@selected == project.name}>
          {project.name}
        </option>
      </select>
    </form>
    """
  end

  attr(:ops, :list, required: true)

  # Audit + land lifecycle, the half of the pipeline RunFeed can't see (separate
  # Oban workers). Each row is one fact-only `OpsFeed.Op` transition; a settled
  # audit carries its (capped) agent transcript in an expandable block, since the
  # audit is a real third-family agent run. Facts only — the audit's own
  # clean/fixed verdict lives in `.harness/audit.json`; this panel just relays it.
  @spec ops_panel(map()) :: Rendered.t()
  defp ops_panel(assigns) do
    ~H"""
    <h2>Audit &amp; land ops</h2>
    <p :if={@ops == []} class="empty-state">
      No merge or audit step has been reported since this page was opened.
    </p>
    <table :if={@ops != []}>
      <caption>Audit and land operations</caption>
      <thead>
        <tr>
          <th scope="col">Kind</th>
          <th scope="col">Stage</th>
          <th scope="col">Project</th>
          <th scope="col">Agent</th>
          <th scope="col">Run / Range</th>
          <th scope="col">SHA</th>
          <th scope="col">Detail</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={op <- @ops}>
          <td><code>{op.kind}</code></td>
          <td><code>{op.stage}</code></td>
          <td>{op.project || "—"}</td>
          <td>{op.agent || "—"}</td>
          <td>{op.run_id || op.range || "—"}</td>
          <td>{ops_sha(op.sha)}</td>
          <td>
            {op.detail || ""}
            <details :if={op.transcript}>
              <summary>transcript</summary>
              <pre class="transcript">{op.transcript}</pre>
            </details>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @spec ops_sha(String.t() | nil) :: String.t()
  defp ops_sha(nil), do: "—"
  defp ops_sha(sha), do: short_sha(sha)

  attr(:id, :string, required: true)
  attr(:rows, :any, required: true)
  attr(:summaries, :map, default: %{})
  attr(:landable_projects, :any, default: MapSet.new())
  attr(:caption, :string, required: true)
  attr(:empty, :boolean, required: true)

  # Shared by the "Active runs" and "Run history" tables. `rows` is a
  # `Phoenix.LiveView` stream; the `<tbody>` carries `phx-update="stream"` and a
  # stable id so inserts/deletes patch individual rows. Settled rows render no
  # kill action — `killable?/1` returns false for terminal states — so the same
  # markup serves both live and historical entries. The Landed cell reads the
  # persisted run-record witness: `status.landed_sha`.
  @spec run_table(map()) :: Rendered.t()
  defp run_table(assigns) do
    ~H"""
    <div :if={!@empty} class="table-scroll run-table-scroll">
      <table class="run-table">
        <caption>{@caption}</caption>
        <thead>
          <tr>
            <th scope="col">Task</th>
            <th scope="col">Project</th>
            <th scope="col">Run</th>
            <th scope="col">Agent</th>
            <th scope="col">Model</th>
            <th scope="col">State</th>
            <th scope="col">Verdict</th>
            <th scope="col">Landed</th>
            <th scope="col">Detail</th>
            <th scope="col">Action</th>
          </tr>
        </thead>
        <tbody id={@id} phx-update="stream">
          <tr
            :for={{dom_id, entry} <- @rows}
            id={dom_id}
            class={entry.status.review_warning? && "has-review-warning"}
          >
            <td data-label="Task">{entry.status.task_id}</td>
            <td data-label="Project">{entry.status.project_name || "—"}</td>
            <td data-label="Run"><.run_link run_id={entry.status.run_id} /></td>
            <td data-label="Agent"><code>{stage_agent_label(entry.status)}</code></td>
            <td data-label="Model">{model_label(entry.status.agent, entry.status.model, "")}</td>
            <td data-label="State">
              <Components.bucket_badge
                bucket={badge_bucket(entry.status.state)}
                label={bucket_label(entry.status.state)}
              />
            </td>
            <td data-label="Verdict">
              {verdict_label(entry.status.review_verdict)}
              <span :if={entry.review_concerns != []} class="review-warning-mark">concerns</span>
              <span
                :if={entry.status.review_warning? and entry.review_concerns == []}
                class="review-warning-mark"
              >failed check</span>
            </td>
            <td data-label="Landed">{landed_label(entry.status)}</td>
            <td data-label="Detail">
              <details :if={entry.detail not in [nil, ""]} class="run-detail-disclosure">
                <summary>{entry.detail}</summary>
                <div>{entry.detail}</div>
              </details>
            </td>
            <td data-label="Action">
              <.row_actions
                status={entry.status}
                summaries={@summaries}
                landable_projects={@landable_projects}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:record, :map, required: true)

  @spec review_testimony(map()) :: Rendered.t()
  defp review_testimony(assigns) do
    ~H"""
    <section
      id="review-testimony"
      class={[
        "run-section",
        "review-testimony",
        @record.review_warning? && "has-review-warning"
      ]}
    >
      <h2>Reviewer testimony</h2>
      <dl class="field">
        <dt :if={is_integer(@record.reviewer_diff_size)}>Reviewer diff size</dt>
        <dd :if={is_integer(@record.reviewer_diff_size)}>
          {@record.reviewer_diff_size} changed lines
        </dd>
      </dl>
      <.review_fact label="Concerns" value={@record.review_concerns} />
      <.review_fact label="Checks" value={@record.review_checks} />
      <.review_fact label="Ratings" value={@record.review_ratings} />
      <.review_fact label="Facets" value={@record.review_facets} />
      <.review_fact label="Skills" value={@record.review_skills} />
      <.review_fact label="Proposed tasks" value={@record.review_proposed_tasks} />
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  @spec review_fact(map()) :: Rendered.t()
  defp review_fact(assigns) do
    ~H"""
    <div :if={present_review_fact?(@value)} class="review-fact">
      <h3>{@label}</h3>
      <pre>{review_fact_text(@value)}</pre>
    </div>
    """
  end

  attr(:status, :map, required: true)

  # Failed-run diagnosis: operator headline + consequence + named recovery,
  # with the raw Erlang term behind a disclosure. Headline is
  # `StatusView.describe_reason/1` so this matches the index Detail cell.
  @spec run_failure(map()) :: Rendered.t()
  defp run_failure(assigns) do
    assigns = assign(assigns, :copy, StatusView.failure_copy(assigns.status))

    ~H"""
    <section class="run-failure" id="run-failure">
      <h2>{@copy.headline}</h2>
      <p>{@copy.consequence}</p>
      <p>Recommended recovery: <code>{@copy.recovery}</code></p>
      <details>
        <summary>Raw reason</summary>
        <pre>{@copy.raw}</pre>
      </details>
    </section>
    """
  end

  attr(:status, :map, required: true)
  attr(:summaries, :map, default: %{})
  attr(:landable_projects, :any, default: MapSet.new())

  # Shared by index rows and the run-detail page. Each button is gated by the
  # existing resumable?/relandable?/landable?/deletable?/killable? predicates
  # — this component does not re-derive those facts.
  @spec row_actions(map()) :: Rendered.t()
  defp row_actions(assigns) do
    ~H"""
    <div class="row-actions">
      <.kill_button
        :if={killable?(@status)}
        run_id={@status.run_id}
        task_id={@status.task_id}
        project_name={@status.project_name}
      />
      <.resume_button
        :if={resumable?(@status)}
        run_id={@status.run_id}
        task_id={@status.task_id}
        project_name={@status.project_name}
      />
      <.resume_button
        :if={resumable?(@status)}
        run_id={@status.run_id}
        task_id={@status.task_id}
        project_name={@status.project_name}
        escalate
      />
      <.reland_button
        :if={relandable?(@status, @summaries)}
        run_id={@status.run_id}
        task_id={@status.task_id}
        project_name={@status.project_name}
      />
      <.reland_button
        :if={landable?(@status, @summaries, @landable_projects)}
        run_id={@status.run_id}
        task_id={@status.task_id}
        project_name={@status.project_name}
        first_land
      />
      <.delete_button
        :if={deletable?(@status)}
        run_id={@status.run_id}
        task_id={@status.task_id}
        project_name={@status.project_name}
      />
    </div>
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
  attr(:task_id, :string, default: nil)
  attr(:project_name, :string, default: nil)

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
      aria-label={row_action_aria_label("Kill run", @run_id, @task_id, @project_name)}
    >
      Kill run
    </button>
    """
  end

  attr(:run_id, :string, required: true)
  attr(:task_id, :string, default: nil)
  attr(:project_name, :string, default: nil)

  # Settled-only affordance: discards the run's persisted history record (e.g. a
  # throwaway smoke run). Confirm-gated since the record is gone for good; routes
  # to the `"delete_run"` handle_event. Never offered for a live run (deletable?/1
  # is true only for terminal states).
  @spec delete_button(map()) :: Rendered.t()
  defp delete_button(assigns) do
    ~H"""
    <button
      type="button"
      class="delete-btn"
      phx-click="delete_run"
      phx-value-run_id={@run_id}
      data-confirm={"Delete run #{@run_id} from history? This removes its record permanently."}
      aria-label={row_action_aria_label("Delete run", @run_id, @task_id, @project_name)}
    >
      Delete
    </button>
    """
  end

  attr(:run_id, :string, required: true)
  attr(:task_id, :string, default: nil)
  attr(:project_name, :string, default: nil)
  attr(:escalate, :boolean, default: false)

  # Failed-only affordance: re-dispatch the run's task on a NEW run branched off
  # the retained harness/<run-id> branch (prior commits as the starting point)
  # with the failure report in the prompt. The plain button reuses the original
  # agent; the escalate variant (phx-value-escalate) routes to a
  # capability-recommended agent. Confirm-gated since it spends agent tokens.
  @spec resume_button(map()) :: Rendered.t()
  defp resume_button(%{escalate: true} = assigns) do
    ~H"""
    <button
      type="button"
      class="resume-btn"
      phx-click="resume_run"
      phx-value-run_id={@run_id}
      phx-value-escalate="true"
      data-confirm={"Escalate run #{@run_id} to a capability-recommended agent? Starts a new run off the failed branch with a different agent."}
      aria-label={row_action_aria_label("Escalate run", @run_id, @task_id, @project_name)}
    >
      Escalate
    </button>
    """
  end

  defp resume_button(assigns) do
    ~H"""
    <button
      type="button"
      class="resume-btn"
      phx-click="resume_run"
      phx-value-run_id={@run_id}
      data-confirm={"Resume run #{@run_id}? Starts a new run off the retained failed branch with the same agent."}
      aria-label={row_action_aria_label("Resume run", @run_id, @task_id, @project_name)}
    >
      Resume
    </button>
    """
  end

  attr(:run_id, :string, required: true)
  attr(:task_id, :string, default: nil)
  attr(:project_name, :string, default: nil)
  attr(:first_land, :boolean, default: false)

  # Offered when the run's task is blocked (a land-cap-exhausted train). Re-enqueues
  # the landing job — zero agent tokens, pure git — confirm-gated; routes to the
  # `"reland_run"` handle_event. The `first_land` variant is the same control for a
  # never-landed approved run of a manual-policy project (`landable?/3`): identical
  # backend, only the label/copy differ ("Land" — first land — vs "Re-land" — retry).
  @spec reland_button(map()) :: Rendered.t()
  defp reland_button(%{first_land: true} = assigns) do
    ~H"""
    <button
      type="button"
      class="reland-btn"
      phx-click="reland_run"
      phx-value-run_id={@run_id}
      data-confirm={"Land run #{@run_id}? Enqueues the landing job (no agent run)."}
      aria-label={row_action_aria_label("Land run", @run_id, @task_id, @project_name)}
    >
      Land
    </button>
    """
  end

  defp reland_button(assigns) do
    ~H"""
    <button
      type="button"
      class="reland-btn"
      phx-click="reland_run"
      phx-value-run_id={@run_id}
      data-confirm={"Re-land run #{@run_id}? Re-enqueues the landing job (no agent run)."}
      aria-label={row_action_aria_label("Re-land run", @run_id, @task_id, @project_name)}
    >
      Re-land
    </button>
    """
  end

  # Builds an unambiguous per-row accessible name for a row action button,
  # since the visible label (e.g. "Delete") repeats identically down every
  # row of the runs table. Task/project are appended only when known — the
  # run-detail page's single-run context has no `task_id`/`project_name` to
  # pass.
  @spec row_action_aria_label(String.t(), String.t(), String.t() | nil, String.t() | nil) :: String.t()
  defp row_action_aria_label(verb, run_id, nil, _project_name), do: "#{verb} #{run_id}"

  defp row_action_aria_label(verb, run_id, task_id, nil), do: "#{verb} #{run_id} (task #{task_id})"

  defp row_action_aria_label(verb, run_id, task_id, project_name),
    do: "#{verb} #{run_id} (task #{task_id}, project #{project_name})"

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

  def handle_event("delete_run", %{"run_id" => run_id}, socket) do
    # Best-effort store delete (mirrors record_run's contract: logged, never fatal),
    # then drop the row from both the live stream and the history_all assign so a
    # later restream (project / landed toggle) doesn't resurrect it.
    _ = ResultStore.delete_run(run_id)

    socket =
      socket
      |> assign(:history_all, prune_history(socket.assigns.history_all, run_id))
      |> stream_delete_by_dom_id(:history, "hist-#{run_id}")

    {:noreply, assign(socket, :history_empty?, history_rows(socket) == [])}
  end

  def handle_event("resume_run", %{"run_id" => run_id} = params, socket) do
    # Re-dispatch a settled :failed run off its retained harness/<run-id> branch
    # (prior commits as the starting point) with the failure report in the prompt.
    # The new run surfaces in Active runs via the RunFeed broadcast; the :notice
    # assign reports the outcome (the bare app layout renders no flash).
    notice =
      case Harness.Dispatch.resume_failed(run_id, params["escalate"] == "true") do
        {:ok, %{run_id: new_run_id, agent: agent}} ->
          {:ok, "Resumed #{run_id} → new run #{new_run_id} on #{agent}."}

        {:error, reason} ->
          {:error, "Resume failed: #{inspect(reason)}"}
      end

    {:noreply, assign(socket, :notice, notice)}
  end

  def handle_event("reland_run", %{"run_id" => run_id}, socket) do
    # Re-enqueue the landing job for a run whose land-train blocked its task
    # (0 agent tokens — pure git). Success surfaces as the Landed column updating
    # on the next roadmap tick; the :notice assign reports the enqueue outcome.
    notice =
      case Harness.Dispatch.reland(run_id) do
        {:ok, %{task_id: task_id}} -> {:ok, "Re-land enqueued for task #{task_id} (run #{run_id})."}
        {:error, reason} -> {:error, "Re-land failed: #{inspect(reason)}"}
      end

    {:noreply, assign(socket, :notice, notice)}
  end

  def handle_event("toggle_landed", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_landed, not socket.assigns.show_landed)
     |> restream_history()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @typep bucket_count_source :: %{
           required(:runs) => [StatusView.run_entry()],
           optional(atom()) => term()
         }

  @doc false
  @spec bucket_counts(bucket_count_source()) :: %{
          required(StatusView.bucket()) => non_neg_integer()
        }
  def bucket_counts(%{runs: runs}) do
    empty = %{dispatched: 0, running: 0, committing: 0, recovering: 0, reviewing: 0, held: 0, done: 0, failed: 0}

    Enum.reduce(runs, empty, fn entry, acc ->
      Map.update(acc, entry.bucket, 1, &(&1 + 1))
    end)
  end

  @doc false
  @spec bucket_label(Status.state()) :: String.t()
  def bucket_label(state), do: Atom.to_string(state)

  @spec count_tiles(map()) :: [{Status.state(), non_neg_integer()}]
  defp count_tiles(counts) do
    for state <- [:dispatched, :running, :committing, :recovering, :reviewing, :held, :done, :failed],
        do: {state, Map.fetch!(counts, state)}
  end

  @typep audit_flight_key :: {String.t() | nil, String.t() | nil}

  @doc false
  @spec track_audit_flights([audit_flight_key()], Op.t()) :: [audit_flight_key()]
  def track_audit_flights(flights, %Op{kind: :audit, stage: :started} = op) do
    [audit_flight_key(op) | flights]
  end

  def track_audit_flights(flights, %Op{kind: :audit} = op) do
    List.delete(flights, audit_flight_key(op))
  end

  def track_audit_flights(flights, %Op{}), do: flights

  # Identity is project + range: `audit_started` has no sha, and `audit_settled`
  # reuses the same `range.log` the start broadcast carried.
  @spec audit_flight_key(Op.t()) :: audit_flight_key()
  defp audit_flight_key(%Op{project: project, range: range}), do: {project, range}

  @spec badge_bucket(Status.state()) :: :in_flight | :repairing | :green | :red
  defp badge_bucket(state) when state in [:dispatched, :running, :committing, :reviewing, :held], do: :in_flight
  defp badge_bucket(:recovering), do: :repairing
  defp badge_bucket(:done), do: :green
  defp badge_bucket(:failed), do: :red

  @spec review_testimony_present?(LogRecord.t() | nil) :: boolean()
  defp review_testimony_present?(nil), do: false

  defp review_testimony_present?(%LogRecord{} = record) do
    is_integer(record.reviewer_diff_size) or
      present_review_fact?(record.review_concerns) or
      present_review_fact?(record.review_checks) or
      present_review_fact?(record.review_ratings) or
      present_review_fact?(record.review_facets) or
      present_review_fact?(record.review_skills) or
      present_review_fact?(record.review_proposed_tasks)
  end

  @spec present_review_fact?(term()) :: boolean()
  defp present_review_fact?(value), do: value not in [nil, "", [], %{}]

  @spec review_fact_text(term()) :: String.t()
  defp review_fact_text(value) when is_binary(value), do: value

  defp review_fact_text(values) when is_list(values) do
    Enum.map_join(values, "\n", &review_fact_item/1)
  end

  defp review_fact_text(value), do: encode_review_fact(value)

  @spec review_fact_item(term()) :: String.t()
  defp review_fact_item(item) when is_binary(item), do: item
  defp review_fact_item(item), do: encode_review_fact(item)

  @spec encode_review_fact(term()) :: String.t()
  defp encode_review_fact(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value, pretty: true, limit: :infinity)
    end
  end

  @doc false
  @spec filter_runs([StatusView.run_entry()], String.t() | nil) :: [StatusView.run_entry()]
  def filter_runs(runs, nil), do: runs

  def filter_runs(runs, project_name) do
    Enum.filter(runs, &(&1.status.project_name == project_name))
  end

  @doc false
  @spec verdict_label(:approve | :reject | nil) :: String.t()
  def verdict_label(:approve), do: "approved"
  def verdict_label(:reject), do: "rejected"
  def verdict_label(nil), do: "—"

  # "Merged" is the run record carrying a landed_sha written by the lander.
  @doc false
  @spec landed_label(Status.t()) :: String.t()
  def landed_label(%Status{} = status) do
    case status.landed_sha do
      nil -> "—"
      sha -> "✓ " <> short_sha(sha)
    end
  end

  @spec short_sha(String.t()) :: String.t()
  defp short_sha(sha), do: String.slice(sha, 0, 7)

  # The executing adapter, resolved from its module (`agent_kind_for/1`) and
  # available the moment a run starts. The `Status.agent_kind` field stays nil
  # until termination, so it is only the fallback — showing the resolved agent
  # makes a live run's adapter legible instead of a perpetual "nil".
  @doc false
  @spec agent_label(Parser.agent_kind() | nil, atom() | nil) :: String.t()
  def agent_label(resolved, status_kind) do
    case resolved || status_kind do
      nil -> "—"
      kind -> to_string(kind)
    end
  end

  # The agent active in the run's *current* stage: the reviewer while
  # `:reviewing`, the recovery agent while `:recovering`, else the implementer.
  # Without this the run tables show the implementer for the run's whole life,
  # so a cross-family reviewer (or recovery) stage is invisible — the row reads
  # as "still the implementer" even though a different agent is now working.
  @doc false
  @spec stage_agent_label(Status.t()) :: String.t()
  def stage_agent_label(%Status{state: :reviewing, agent_kind: :recovery_review, reviewer_adapter: reviewer})
      when not is_nil(reviewer), do: "recovery reviewer: " <> agent_label(reviewer, nil)

  def stage_agent_label(%Status{state: :reviewing, reviewer_adapter: reviewer}) when not is_nil(reviewer),
    do: agent_label(reviewer, nil)

  def stage_agent_label(%Status{state: :recovering, recovery_adapter: recovery}) when not is_nil(recovery),
    do: agent_label(recovery, nil)

  def stage_agent_label(%Status{agent: agent}), do: agent_label(agent, nil)

  # Which agent row gets the live pulsing dot on the run-detail header.
  @doc false
  @spec active_agent_role(Status.t()) :: :implementer | :reviewer | :recovery_review | :recovery | nil
  def active_agent_role(%Status{state: :running}), do: :implementer
  def active_agent_role(%Status{state: :reviewing, agent_kind: :recovery_review}), do: :recovery_review
  def active_agent_role(%Status{state: :reviewing}), do: :reviewer
  def active_agent_role(%Status{state: :recovering}), do: :recovery
  def active_agent_role(_status), do: nil

  @spec run_agent_class(:implementer | :reviewer | :recovery_review | :recovery, Status.t()) :: String.t()
  defp run_agent_class(role, status) do
    if active_agent_class?(role, status), do: "run-agent run-agent-active", else: "run-agent"
  end

  @spec active_agent_class?(:implementer | :reviewer | :recovery_review | :recovery, Status.t()) :: boolean()
  defp active_agent_class?(:reviewer, status), do: active_agent_role(status) in [:reviewer, :recovery_review]
  defp active_agent_class?(role, status), do: active_agent_role(status) == role

  @spec reviewer_detail_label(Status.t()) :: String.t()
  defp reviewer_detail_label(%Status{state: :reviewing, agent_kind: :recovery_review} = status),
    do: stage_agent_label(status)

  defp reviewer_detail_label(%Status{reviewer_adapter: reviewer}), do: agent_label(reviewer, nil)

  # Parser kind for live token totals — follow the active stage's agent so a
  # reviewing run parses the reviewer's stream, not the implementer's adapter.
  @doc false
  @spec stage_token_agent_kind(Status.t(), Parser.agent_kind() | nil) :: Parser.agent_kind() | nil
  def stage_token_agent_kind(%Status{state: :reviewing, reviewer_adapter: reviewer}, _fallback) when not is_nil(reviewer),
    do: reviewer

  def stage_token_agent_kind(%Status{state: :recovering, recovery_adapter: recovery}, _fallback)
      when not is_nil(recovery), do: recovery

  def stage_token_agent_kind(%Status{agent: agent}, _fallback) when not is_nil(agent), do: agent
  def stage_token_agent_kind(_status, fallback), do: fallback

  # Token burn parsed from the captured transcript with the same per-adapter
  # parser the KPI ledger uses — works for a live (partial) or settled (full)
  # transcript. Agents that report no usage (grok-without-usage, antigravity)
  # The model the agent reported using. Prefers the value stored on the settled
  # record; for a live run (no record yet) it parses the captured transcript,
  # since claude/cursor name the model early in their stream. Agents that never
  # report a model fall back to the task's requested model; when only that is
  # known, the label carries a "(requested)" hint.
  @doc false
  @spec model_label(Parser.agent_kind() | nil, String.t() | nil, binary()) :: String.t()
  def model_label(agent_kind, stored, transcript) do
    reported = Harness.AgentModel.parse(agent_kind, transcript)

    cond do
      is_binary(stored) and stored != "" ->
        if is_nil(reported) and requested_only_agent?(agent_kind),
          do: "#{stored} (requested)",
          else: stored

      is_binary(reported) ->
        reported

      true ->
        "—"
    end
  end

  @spec requested_only_agent?(Parser.agent_kind() | nil) :: boolean()
  defp requested_only_agent?(agent) when agent in [:codex, :grok, :antigravity, :pi], do: true
  defp requested_only_agent?(_agent), do: false

  # honestly render "—" rather than a misleading 0.
  @doc false
  @spec token_label(Parser.agent_kind() | nil, binary()) :: String.t()
  def token_label(agent_kind, transcript) do
    usage = token_usage(agent_kind, transcript)

    if Harness.TokenUsage.measured?(usage) do
      usage.total
      |> Integer.to_string()
      |> Components.delimit()
    else
      "—"
    end
  end

  # Grok omits usage on stdout; recover its cumulative total from the on-disk
  # session log so the run-detail row matches the KPI rollup rather than reading
  # "—" against a real figure.
  @spec token_usage(Parser.agent_kind() | nil, binary()) :: Harness.TokenUsage.t()
  defp token_usage(:grok, transcript) do
    case Harness.TokenUsage.parse(:grok, transcript) do
      %Harness.TokenUsage{} = usage when usage.total != nil -> usage
      _ -> GrokSession.usage(transcript)
    end
  end

  defp token_usage(agent_kind, transcript), do: Harness.TokenUsage.parse(agent_kind, transcript)

  @doc false
  @spec killable?(Status.t() | nil) :: boolean()
  def killable?(%Status{state: state}) when state in [:done, :failed], do: false
  def killable?(%Status{}), do: true
  def killable?(nil), do: false

  # The inverse of killable?/1: only a settled run has a persisted history record
  # to discard, so the Delete affordance is offered exactly for terminal states.
  @doc false
  @spec deletable?(Status.t() | nil) :: boolean()
  def deletable?(%Status{state: state}) when state in [:done, :failed], do: true
  def deletable?(%Status{}), do: false
  def deletable?(nil), do: false

  # A settled :failed run can be resumed: re-dispatched off its retained
  # harness/<run-id> branch with the failure report as guidance. :done runs land
  # (or re-land); live runs are killed/steered, not resumed.
  @doc false
  @spec resumable?(Status.t() | nil) :: boolean()
  def resumable?(%Status{state: :failed}), do: true
  def resumable?(%Status{}), do: false
  def resumable?(nil), do: false

  # A run is re-landable when its roadmap task is blocked — the shape a land-cap
  # -exhausted merge-train leaves behind. The operator reads the blocked reason in
  # the row, then re-enqueues the landing job. (Mechanical gate; the human decides.)
  @doc false
  @spec relandable?(Status.t() | nil, RoadmapSummary.summaries()) :: boolean()
  def relandable?(%Status{project_name: project, task_id: task_id}, summaries),
    do: RoadmapSummary.blocked?(summaries, project, task_id)

  def relandable?(nil, _summaries), do: false

  # A run is (first-)landable when it settled :done with an :approve verdict, the
  # run has no landed_sha and isn't blocked (that's relandable?/2's case), and
  # its project is in `landable_projects` — the manual-policy projects
  # with a target_branch (see landable_project_names/1). Manual-policy projects
  # never auto-enqueue a land, so this is the operator's first merge trigger; the
  # backend is identical to re-land (Lander.enqueue/1).
  @doc false
  @spec landable?(Status.t() | nil, RoadmapSummary.summaries(), MapSet.t(String.t())) :: boolean()
  def landable?(
        %Status{state: :done, review_verdict: :approve, project_name: project, task_id: task_id} = status,
        summaries,
        landable_projects
      )
      when is_binary(project) do
    MapSet.member?(landable_projects, project) and
      status.landed_sha == nil and
      not RoadmapSummary.blocked?(summaries, project, task_id)
  end

  def landable?(_status, _summaries, _landable_projects), do: false

  # The set of project names where a manual "Land" button can succeed: manual
  # landing policy (auto projects land via the train) AND a configured
  # target_branch (Lander.land/1 bails without one). Gating the button on this set
  # keeps it hidden until landing can actually work.
  @doc false
  @spec landable_project_names([Project.t()]) :: MapSet.t(String.t())
  def landable_project_names(projects) do
    for %Project{name: name, landing_policy: :manual, target_branch: tb} <- projects,
        is_binary(tb) and tb != "",
        into: MapSet.new(),
        do: name
  end
end
