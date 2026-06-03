defmodule Harness.Dashboard.CompareLive do
  @moduledoc """
  A/B agent-evaluation view (Task 81) — one roadmap task run across N adapters,
  side by side.

  ## Two actions, one LiveView

    * `:index` (`/harness/compare`) — the launch form: pick a project + task id +
      ≥2 adapters, submit, and the comparison starts.
    * `:show` (`/harness/compare/:comparison_id`) — the N-lane grid. Each adapter
      is a vertical lane whose dominant element is the verdict cell; click a lane
      header to switch the lower transcript pane to that adapter's run.

  ## How the launch threads to the grid

  `Harness.Batch.AgentEvaluation.compare/4` is **synchronous** — it blocks until
  every pinned run settles. So `handle_event("compare", …)` ingests the item,
  generates the `batch_id` that becomes the URL's `comparison_id`, spawns
  `compare/4` in an unlinked process (it messages `{:comparison_done, result}`
  back), and `push_patch`es to `:show`. The LiveView process survives the patch,
  so the in-memory comparison state carries straight into the grid.

  ## Live correlation — `(task_id, agent)`, not `batch_id`

  `Harness.Run.Status` carries `run_id`, `task_id`, and `agent` but **no
  `batch_id`**, so the fleet-wide `RunFeed` can't be filtered by batch. A
  comparison pins ONE task across DISTINCT adapters, so `(task_id, agent)`
  uniquely keys each lane — that's the correlation key. The async `compare/4`
  result is a final-reconcile convenience, not the source of truth: the lanes
  fill from `RunFeed` regardless of whether that process survives.

  ## Transcripts — bounded assigns lists, not `stream/3`

  Task 81's acceptance criteria asked for a per-adapter `stream/3` AND for reuse
  of the Task-87 `Components.transcript_view/1`. Those two pull apart:
  `transcript_view/1` *groups* a full event list (collapses consecutive thoughts,
  attaches tool-calls to the owning assistant message), which a per-event
  `stream_insert` can't express. The MB-scale accumulation the `stream/3` AC
  guards against is already solved upstream — `Harness.Dashboard.Transcript`
  FIFO-caps the parsed event list at `event_count_cap/0` (500) — so each lane
  holds its own *bounded* event list in assigns and re-renders `transcript_view`,
  exactly as the run-detail page (`Harness.Dashboard.Live`) already does. This
  reuses the mandated component and respects the bounded-memory intent; the
  literal `stream/3` shape is the deliberate deviation.
  """

  use Phoenix.LiveView

  alias Harness.AgentRegistry
  alias Harness.Batch.AgentEvaluation
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.Dashboard.Components
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.TokenUsage
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @metric_rows [
    {:duration_ms, "duration"},
    {:agent_diff_size, "diff size"},
    {:reviewer_diff_size, "reviewer fix size"},
    {:tokens, "tokens"}
  ]

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: RunFeed.subscribe()

    {:ok,
     socket
     |> assign(:projects, ProjectRegistry.list())
     |> assign(:adapters, AgentRegistry.agents())
     |> assign(:error, nil)
     |> reset_comparison()}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @spec apply_action(Socket.t(), atom(), map()) :: Socket.t()
  defp apply_action(socket, :index, _params), do: reset_comparison(socket)

  defp apply_action(socket, :show, %{"comparison_id" => id} = params) do
    socket =
      if socket.assigns.comparison_id == id,
        do: socket,
        else: load_comparison(socket, id)

    assign(socket, :active_adapter, active_tab(params, socket.assigns.adapter_order, socket.assigns.active_adapter))
  end

  # A fresh `:show` mount (reload / shared link) has no in-memory comparison.
  # Rebuild settled lanes from the persisted batch's run records when the store
  # has them; otherwise render an empty grid the RunFeed can still fill if the
  # runs are somehow live. Per the task's out-of-scope, no cross-restart archive
  # is built — this is best-effort reconstruction of an already-recorded batch.
  @spec load_comparison(Socket.t(), String.t()) :: Socket.t()
  defp load_comparison(socket, id) do
    socket = socket |> reset_comparison() |> assign(:comparison_id, id)

    case ResultStore.list_run_records(ResultStore.configured(), batch_id: id) do
      {:ok, [_ | _] = records} -> hydrate_from_records(socket, records)
      _ -> socket
    end
  end

  @spec hydrate_from_records(Socket.t(), [LogRecord.t()]) :: Socket.t()
  defp hydrate_from_records(socket, records) do
    pairs = Enum.map(records, &{record_agent(&1), &1})
    order = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    socket
    |> assign(:task_id, hd(records).task_id)
    |> assign(:adapter_order, order)
    |> assign(:columns, Map.new(pairs, fn {agent, rec} -> {agent, column_from_record(agent, rec)} end))
    |> assign(:transcripts, Map.new(pairs, fn {agent, rec} -> {agent, transcript_from_record(rec)} end))
    |> assign(:run_to_adapter, Map.new(pairs, fn {agent, rec} -> {rec.run_id, agent} end))
    |> assign(:active_adapter, List.first(order))
  end

  # LogRecord.agent is set on the batch path; a direct run leaves it nil, so fall
  # back to reverse-mapping the adapter module against the registry.
  @spec record_agent(LogRecord.t()) :: atom()
  defp record_agent(%LogRecord{agent: agent}) when is_atom(agent) and not is_nil(agent), do: agent

  defp record_agent(%LogRecord{adapter: adapter}) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, agent} -> agent
      _ -> adapter
    end
  end

  @spec active_tab(map(), [atom()], atom() | nil) :: atom() | nil
  defp active_tab(%{"tab" => tab}, order, fallback) do
    Enum.find(order, fallback, &(Atom.to_string(&1) == tab))
  end

  defp active_tab(_params, order, fallback), do: fallback || List.first(order)

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("compare", params, socket) do
    with {:ok, project} <- lookup_project(params["project"]),
         {:ok, adapters} <- selected_adapters(params),
         task_id when is_binary(task_id) and task_id != "" <- String.trim(params["task_id"] || ""),
         {:ok, item} <- Roadmap.ingest({:id, task_id}, project: project, agent: hd(adapters).agent) do
      {:noreply, launch(socket, project, item, adapters)}
    else
      "" -> {:noreply, assign(socket, :error, "Enter a task id.")}
      {:error, reason} -> {:noreply, assign(socket, :error, "Could not start comparison: #{inspect(reason)}")}
    end
  end

  @spec launch(Socket.t(), Harness.Project.t(), Harness.Roadmap.Item.t(), [map()]) :: Socket.t()
  defp launch(socket, project, item, adapters) do
    id = "compare-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    modules = Enum.map(adapters, & &1.module)
    order = Enum.map(adapters, & &1.agent)
    lv = self()

    spawn(fn ->
      result =
        try do
          AgentEvaluation.compare(item, project, modules, batch_id: id, max_concurrency: length(modules))
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, Exception.format_banner(kind, reason)}
        end

      send(lv, {:comparison_done, result})
    end)

    socket
    |> assign(:error, nil)
    |> assign(:comparison_id, id)
    |> assign(:task_id, item.id)
    |> assign(:adapter_order, order)
    |> assign(:columns, Map.new(adapters, &{&1.agent, pending_column(&1)}))
    |> assign(:transcripts, Map.new(order, &{&1, empty_transcript()}))
    |> assign(:run_to_adapter, %{})
    |> assign(:active_adapter, List.first(order))
    |> push_patch(to: "/harness/compare/#{id}")
  end

  @impl Phoenix.LiveView
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info({:harness_run_update, %Status{} = status}, socket) do
    {:noreply, apply_status(socket, status, false)}
  end

  def handle_info({:harness_run_settled, %Status{} = status}, socket) do
    {:noreply, apply_status(socket, status, true)}
  end

  def handle_info({:harness_transcript_events, run_id, seq, events}, socket) do
    {:noreply, apply_transcript(socket, run_id, seq, events)}
  end

  def handle_info({:comparison_done, {:ok, %Comparison{entries: entries}}}, socket) do
    {:noreply, assign(socket, :columns, reconcile(socket.assigns.columns, entries))}
  end

  def handle_info({:comparison_done, {:error, reason}}, socket) do
    {:noreply, assign(socket, :error, "Comparison failed: #{inspect(reason)}")}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # A RunFeed status belongs to this comparison iff it shares the task and its
  # agent is one of the lanes. First sighting of a lane's run subscribes to its
  # transcript so the lower pane can fill.
  @spec apply_status(Socket.t(), Status.t(), boolean()) :: Socket.t()
  defp apply_status(%{assigns: %{task_id: task_id}} = socket, %Status{task_id: task_id, agent: agent} = status, settled?)
       when is_atom(agent) do
    case socket.assigns.columns[agent] do
      nil -> socket
      column -> socket |> track_run(agent, status) |> put_column(agent, merge_status(column, status, settled?))
    end
  end

  defp apply_status(socket, _status, _settled?), do: socket

  @spec track_run(Socket.t(), atom(), Status.t()) :: Socket.t()
  defp track_run(socket, agent, %Status{run_id: run_id, agent: kind}) do
    if Map.has_key?(socket.assigns.run_to_adapter, run_id) do
      socket
    else
      if connected?(socket), do: Transcript.subscribe(run_id)

      socket
      |> assign(:run_to_adapter, Map.put(socket.assigns.run_to_adapter, run_id, agent))
      |> update(:transcripts, &put_in(&1, [agent, :agent_kind], kind))
    end
  end

  @spec apply_transcript(Socket.t(), String.t(), non_neg_integer(), [term()]) :: Socket.t()
  defp apply_transcript(socket, run_id, seq, events) do
    with agent when is_atom(agent) <- socket.assigns.run_to_adapter[run_id],
         %{last_seq: last} = pane when seq > last <- socket.assigns.transcripts[agent] do
      bounded = Enum.take(pane.events ++ events, -Transcript.event_count_cap())
      put_transcript(socket, agent, %{pane | events: bounded, last_seq: seq})
    else
      _ -> socket
    end
  end

  # Replace each live lane with the authoritative per-adapter metrics once the
  # synchronous compare/4 returns; lanes the feed never reached still settle here.
  @spec reconcile(map(), [Entry.t()]) :: map()
  defp reconcile(columns, entries) do
    Enum.reduce(entries, columns, fn %Entry{} = entry, acc ->
      case AgentRegistry.agent_for_module(entry.adapter) do
        {:ok, agent} when is_map_key(acc, agent) -> Map.put(acc, agent, column_from_entry(acc[agent], entry))
        _ -> acc
      end
    end)
  end

  ## --- render ---------------------------------------------------------------

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  @spec render_index(map()) :: Rendered.t()
  defp render_index(assigns) do
    ~H"""
    <div class="compare-launch">
      <header class="compare-launch-head">
        <h1>A/B agent evaluation</h1>
        <p class="setting-sub">
          Run one task across several adapters and compare verdicts side by side.
        </p>
      </header>

      <p :if={@error} class="setting-warn">{@error}</p>

      <form phx-submit="compare" class="compare-form">
        <label class="compare-field">
          <span>Project</span>
          <select name="project">
            <option :for={p <- @projects} value={p.name}>{p.name}</option>
          </select>
        </label>

        <label class="compare-field">
          <span>Task id</span>
          <input type="text" name="task_id" placeholder="e.g. 25" autocomplete="off" />
        </label>

        <fieldset class="compare-field compare-adapters">
          <legend>Adapters <span class="compare-hint">(pick at least two)</span></legend>
          <label :for={{agent, _module} <- @adapters} class="compare-adapter-check">
            <input type="checkbox" name="adapters[]" value={agent} /> {agent}
          </label>
        </fieldset>

        <button type="submit" class="compare-submit">Run comparison</button>
      </form>
    </div>
    """
  end

  @spec render_show(map()) :: Rendered.t()
  defp render_show(assigns) do
    ~H"""
    <div class="compare-bleed">
      <header class="compare-head">
        <div>
          <a href="/harness/compare" class="compare-back">← new comparison</a>
          <h1>task {@task_id || "—"}</h1>
        </div>
        <code class="compare-id">{@comparison_id}</code>
      </header>

      <p :if={@error} class="setting-warn">{@error}</p>

      <div :if={@adapter_order == []} class="empty-state">
        No live comparison for this id. Start one from the <a href="/harness/compare">launch form</a>.
      </div>

      <div
        :if={@adapter_order != []}
        class="compare-grid"
        style={"--lanes: #{length(@adapter_order)}"}
      >
        <section
          :for={agent <- @adapter_order}
          class={["compare-lane", @active_adapter == agent && "is-active"]}
        >
          <.lane_header
            agent={agent}
            active?={@active_adapter == agent}
            comparison_id={@comparison_id}
            bucket={column_bucket(@columns[agent])}
          />
          <.verdict_cell column={@columns[agent]} />
          <dl class="compare-metrics">
            <.metric_row
              :for={{key, label} <- metric_rows()}
              label={label}
              value={metric(@columns[agent], key)}
            />
          </dl>
        </section>
      </div>

      <section :if={@adapter_order != []} class="compare-transcript">
        <h2 class="eyebrow"><span class="eyebrow-kind">{@active_adapter} transcript</span></h2>
        <Components.transcript_view
          events={transcript_events(@transcripts, @active_adapter)}
          agent={transcript_agent(@transcripts, @active_adapter)}
        />
      </section>
    </div>
    """
  end

  attr(:agent, :atom, required: true)
  attr(:active?, :boolean, required: true)
  attr(:comparison_id, :string, required: true)
  attr(:bucket, :atom, required: true)

  @doc false
  @spec lane_header(map()) :: Rendered.t()
  def lane_header(assigns) do
    ~H"""
    <button
      type="button"
      class="compare-lane-head"
      aria-pressed={to_string(@active?)}
      phx-click={JS.patch("/harness/compare/#{@comparison_id}?tab=#{@agent}")}
    >
      <span class="compare-lane-name">{@agent}</span>
      <Components.bucket_badge bucket={@bucket} />
    </button>
    """
  end

  attr(:column, :map, required: true)

  @doc false
  @spec verdict_cell(map()) :: Rendered.t()
  def verdict_cell(assigns) do
    assigns = assign(assigns, :verdict, verdict_label(assigns.column))

    ~H"""
    <div class="compare-verdict" data-verdict={@verdict.tone}>
      <span class="compare-verdict-mark" aria-hidden="true">{@verdict.glyph}</span>
      <span class="compare-verdict-text">{@verdict.text}</span>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  @doc false
  @spec metric_row(map()) :: Rendered.t()
  def metric_row(assigns) do
    ~H"""
    <div class="compare-metric">
      <dt>{@label}</dt>
      <dd>{@value}</dd>
    </div>
    """
  end

  ## --- column + transcript helpers ------------------------------------------

  @spec metric_rows() :: [{atom(), String.t()}]
  defp metric_rows, do: @metric_rows

  # Drops all comparison state. Unsubscribes any transcript topics the previous
  # comparison subscribed to (mount has no :run_to_adapter assign yet — default
  # to %{} so this is a no-op there).
  @spec reset_comparison(Socket.t()) :: Socket.t()
  defp reset_comparison(socket) do
    socket.assigns
    |> Map.get(:run_to_adapter, %{})
    |> Enum.each(fn {run_id, _adapter} -> Transcript.unsubscribe(run_id) end)

    socket
    |> assign(:comparison_id, nil)
    |> assign(:task_id, nil)
    |> assign(:adapter_order, [])
    |> assign(:columns, %{})
    |> assign(:transcripts, %{})
    |> assign(:run_to_adapter, %{})
    |> assign(:active_adapter, nil)
  end

  @spec pending_column(map()) :: map()
  defp pending_column(%{agent: agent, module: module}) do
    %{
      adapter: agent,
      module: module,
      run_id: nil,
      state: nil,
      verdict: nil,
      duration_ms: nil,
      agent_diff_size: nil,
      reviewer_diff_size: nil,
      token_usage: TokenUsage.empty(),
      settled?: false
    }
  end

  @spec empty_transcript() :: map()
  defp empty_transcript, do: %{events: [], last_seq: 0, agent_kind: nil}

  @spec merge_status(map(), Status.t(), boolean()) :: map()
  defp merge_status(column, %Status{} = status, settled?) do
    %{
      column
      | run_id: status.run_id,
        state: status.state,
        verdict: status.review_verdict || column.verdict,
        settled?: settled? || column.settled?
    }
  end

  @spec column_from_entry(map(), Entry.t()) :: map()
  defp column_from_entry(column, %Entry{} = entry) do
    %{
      column
      | run_id: entry.run_id,
        state: entry.state,
        verdict: entry.verdict,
        duration_ms: entry.duration_ms,
        agent_diff_size: entry.agent_diff_size,
        reviewer_diff_size: entry.reviewer_diff_size,
        token_usage: entry.token_usage,
        settled?: true
    }
  end

  @spec column_from_record(atom(), LogRecord.t()) :: map()
  defp column_from_record(agent, %LogRecord{} = record) do
    %{
      adapter: agent,
      module: record.adapter,
      run_id: record.run_id,
      state: record.state,
      verdict: record.verdict,
      duration_ms: record.duration_ms,
      agent_diff_size: record.agent_diff_size,
      reviewer_diff_size: record.reviewer_diff_size,
      token_usage: record.token_usage || TokenUsage.empty(),
      settled?: true
    }
  end

  # Backfill a settled run's transcript pane from its captured output, parsed
  # through the executing agent's parser (mirrors Harness.Dashboard.Live's
  # replay path). An unresolvable parser kind leaves an empty pane.
  @spec transcript_from_record(LogRecord.t()) :: map()
  defp transcript_from_record(%LogRecord{agent_output: output} = record) do
    kind = record_agent(record)

    if is_map_key(AgentRegistry.agents(), kind) do
      events = Parser.replay(kind, output)
      %{events: Enum.take(events, -Transcript.event_count_cap()), last_seq: 0, agent_kind: kind}
    else
      empty_transcript()
    end
  end

  @spec put_column(Socket.t(), atom(), map()) :: Socket.t()
  defp put_column(socket, agent, column) do
    assign(socket, :columns, Map.put(socket.assigns.columns, agent, column))
  end

  @spec put_transcript(Socket.t(), atom(), map()) :: Socket.t()
  defp put_transcript(socket, agent, pane) do
    assign(socket, :transcripts, Map.put(socket.assigns.transcripts, agent, pane))
  end

  @spec transcript_events(map(), atom() | nil) :: [term()]
  defp transcript_events(transcripts, agent) do
    case transcripts[agent] do
      %{events: events} -> events
      _ -> []
    end
  end

  @spec transcript_agent(map(), atom() | nil) :: atom() | nil
  defp transcript_agent(transcripts, agent) do
    case transcripts[agent] do
      %{agent_kind: kind} -> kind
      _ -> nil
    end
  end

  # Lane bucket badge — review in flight reads amber, terminal verdict reads
  # approved/rejected, anything else is in-flight.
  @spec column_bucket(map() | nil) :: atom()
  defp column_bucket(%{verdict: :approve}), do: :green
  defp column_bucket(%{verdict: :reject}), do: :red
  defp column_bucket(%{state: :failed}), do: :red
  defp column_bucket(%{state: :reviewing}), do: :repairing
  defp column_bucket(_), do: :in_flight

  @spec verdict_label(map() | nil) :: %{tone: String.t(), glyph: String.t(), text: String.t()}
  defp verdict_label(%{verdict: :approve}), do: %{tone: "pass", glyph: "●", text: "approved"}
  defp verdict_label(%{verdict: :reject}), do: %{tone: "fail", glyph: "✗", text: "rejected"}
  defp verdict_label(%{state: :failed}), do: %{tone: "fail", glyph: "✗", text: "failed"}

  defp verdict_label(%{state: state}) when state in [:running, :committing, :reviewing, :dispatched],
    do: %{tone: "pending", glyph: "◌", text: to_string(state)}

  defp verdict_label(_), do: %{tone: "pending", glyph: "◌", text: "queued"}

  @spec metric(map() | nil, atom()) :: String.t()
  defp metric(nil, _key), do: "—"
  defp metric(%{duration_ms: nil}, :duration_ms), do: "—"
  defp metric(%{duration_ms: ms}, :duration_ms), do: "#{ms} ms"
  defp metric(%{agent_diff_size: nil}, :agent_diff_size), do: "—"
  defp metric(%{agent_diff_size: n}, :agent_diff_size), do: "#{n} B"
  defp metric(%{reviewer_diff_size: nil}, :reviewer_diff_size), do: "—"
  defp metric(%{reviewer_diff_size: n}, :reviewer_diff_size), do: "#{n} B"
  defp metric(%{token_usage: usage}, :tokens), do: token_label(usage)

  @spec token_label(TokenUsage.t()) :: String.t()
  defp token_label(%TokenUsage{total: total}) when is_integer(total), do: to_string(total)
  defp token_label(_), do: "—"

  ## --- launch-form helpers --------------------------------------------------

  @spec lookup_project(term()) :: {:ok, Harness.Project.t()} | {:error, term()}
  defp lookup_project(name) when is_binary(name) and name != "", do: ProjectRegistry.lookup(name)
  defp lookup_project(_name), do: {:error, :no_project}

  # Maps the checked agent atoms back to %{agent, module} pairs in registry order,
  # rejecting fewer than two (a comparison of one is just a run).
  @spec selected_adapters(map()) :: {:ok, [map()]} | {:error, :need_two_adapters}
  defp selected_adapters(params) do
    chosen = MapSet.new(List.wrap(params["adapters"]))

    adapters =
      for {agent, module} <- AgentRegistry.agents(),
          MapSet.member?(chosen, Atom.to_string(agent)),
          do: %{agent: agent, module: module}

    if length(adapters) >= 2, do: {:ok, adapters}, else: {:error, :need_two_adapters}
  end
end
