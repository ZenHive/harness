defmodule Harness.Dashboard.KPILive do
  @moduledoc """
  Per-agent KPI ledger LiveView (Task 115).

  Renders `Harness.ResultStore.aggregate_by_agent/0` over every persisted run
  record as a
  sortable per-agent table: run count, reviewer-flaked count (review_stuck runs
  excluded from the implementer's success denominator), success rate,
  first-attempt-pass rate, mean repair attempts, mean tokens, cost-to-green, and
  the reviewer's mean ratings. This is the at-a-glance *trust ledger* — the
  question "what is each agent's track record across all runs?" answered in one
  view, closing the user's stated gap (we had the data via `Harness.AgentKPI`
  but no way to see it at once).

  A second *reviewer reliability* table renders
  `Harness.ResultStore.aggregate_reviewer_reliability/0`, keyed by the reviewer
  adapter that gated each run: rejection rate and no-verdict (review_stuck) rate
  — the cross-family reviewer's verdict-write reliability, sorted
  worst-first.

  A small *orchestration health* section renders
  `Harness.ResultStore.aggregate_review_stuck_causes/0`, counting
  `review_stuck` records by the persisted reason detail. This catches
  selection-time failures where `reviewer_adapter` is nil, so they belong to
  harness health rather than any reviewer ledger.

  The reviewer-ratings columns are derived from the union of rating keys present
  across the ledger (the reviewer's keys are free-form), so a reviewer that adds
  a new rating dimension surfaces a new column with no code change.

  ## Relationship to Task 81 (`CompareLive`) — deliberate siblings

  `CompareLive` (Task 81, pending) is a *per-comparison A/B* surface: launch N
  adapters against one task, then read their side-by-side metrics + transcripts
  for that single comparison. This view is the *fleet-wide aggregate* over every
  run ever persisted. Different data (one transient comparison vs the whole
  history), different question ("which adapter wins this A/B?" vs "what is each
  agent's record?"), different lifecycle (launched-on-demand vs always-on). They
  are kept as separate surfaces rather than merged into one — neither subsumes
  the other.

  ## Live, not polled

  Records are read from `Harness.ResultStore` once at mount and re-read whenever
  a run settles (`Harness.Dashboard.RunFeed` `:harness_run_settled`) — the only
  event that adds a `LogRecord` and so the only one that moves the aggregates.
  In-flight transitions are ignored.

  ## By task-facet (Task 225)

  Below the flat fleet-wide tables, the same per-agent facts are pivoted by the
  reviewer-assigned **task facets** (`review_facets`, the routing KEY from Task
  224) via `Harness.CapabilityScore.group_by_facet/1`. Each facet group shows
  its per-agent ledger — approve%, first-try%, reviewer-quality (mean rating),
  mean tokens, cost-to-green — answering "who is best at THIS kind of task?",
  not just fleet-wide. A facet-pill bar filters to one group; the unfaceted
  bucket (records the reviewer left untagged) always renders and is never
  dropped.

  Beside the fact ledger renders the **scout's written verdict** for that facet
  (`Harness.CapabilityScore.read_assessment/1`, Task 216): the winning agent and
  its plain-prose reasoning. Facts (what happened, counted by harness) and the
  AI-written meaning (who to use, written by the scout) sit side by side — the
  page never recomputes a routing verdict from the numbers. A facet with no
  assessment entry shows "no scout verdict yet"; an absent artifact degrades the
  whole column gracefully.

  ## Recovery facts (Task 235)

  The page also renders `Harness.ResultStore.aggregate_recovery_facts/0`: raw
  recovery attempts, repaired/dead outcomes, repair notes, and recovery token
  spend. It exposes the masked-failure rate and token cost the v0_14 hypothesis
  needs, but leaves "is recovery worth it?" synthesis to the AI-facing
  ResultStore API.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.AgentKPI
  alias Harness.CapabilityScore
  alias Harness.CapabilityScore.Assessment
  alias Harness.CapabilityScore.Entry
  alias Harness.Dashboard.RunFeed
  alias Harness.ResultStore
  alias Harness.Run.Status
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @default_sort :run_count
  @default_dir :desc

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: RunFeed.subscribe()

    {:ok,
     socket
     |> assign(:sort_by, @default_sort)
     |> assign(:sort_dir, @default_dir)
     |> assign(:facet_filter, nil)
     |> assign_rows()
     |> assign_facets()}
  end

  # Only a settled run mints a new LogRecord, so it is the only event that can
  # move the aggregates; in-flight updates are ignored to avoid needless re-reads.
  @impl Phoenix.LiveView
  def handle_info({:harness_run_settled, %Status{}}, socket) do
    {:noreply, socket |> assign_rows() |> assign_facets()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # Re-sorts the rows already in assigns — a sort click changes only the order,
  # so it never re-reads the store (assign_rows/1 does, on mount and settle).
  @impl Phoenix.LiveView
  def handle_event("sort", %{"col" => col}, socket) do
    socket = toggle_sort(socket, col)
    rows = sort_rows(socket.assigns.rows, socket.assigns.sort_by, socket.assigns.sort_dir)
    {:noreply, assign(socket, :rows, rows)}
  end

  # An empty key clears the filter (the "All" pill); any other selects one facet
  # group by its label. Clicking the active pill toggles back to "All".
  def handle_event("facet", %{"key" => key}, socket) do
    selected = if key == "" or key == socket.assigns.facet_filter, do: nil, else: key
    {:noreply, assign(socket, :facet_filter, selected)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Read the store, aggregate, flatten to rows, sort by the current key/dir. A
  # store read error degrades to an empty ledger (rendered as the no-data state).
  @spec assign_rows(Socket.t()) :: Socket.t()
  defp assign_rows(socket) do
    rows =
      case ResultStore.aggregate_by_agent() do
        {:ok, ledger} -> to_rows(ledger)
        _error -> []
      end

    socket
    |> assign(:rows, sort_rows(rows, socket.assigns.sort_by, socket.assigns.sort_dir))
    |> assign(:summary, fleet_summary(rows))
    |> assign(:rating_keys, rating_keys(rows))
    |> assign(:reviewer_rows, reviewer_rows())
    |> assign(:review_stuck_cause_rows, review_stuck_cause_rows())
    |> assign(:recovery_facts, recovery_facts())
  end

  @typedoc "Fleet-wide headline rollup over the per-agent rows (counts, not verdicts)."
  @type fleet_summary :: %{
          total_runs: non_neg_integer(),
          success_rate: float(),
          first_pass_rate: float(),
          total_tokens: non_neg_integer(),
          agents: non_neg_integer()
        }

  # Fold the per-agent rows into the at-a-glance headline. Pure counting: sums of
  # run counts/tokens and run-weighted rates — never a new verdict or score.
  @spec fleet_summary([map()]) :: fleet_summary()
  defp fleet_summary(rows) do
    attributable = Enum.sum(Enum.map(rows, &(&1.run_count - &1.reviewer_flaked)))

    %{
      total_runs: Enum.sum(Enum.map(rows, & &1.run_count)),
      success_rate: weighted_rate(rows, :success_rate, attributable),
      first_pass_rate: weighted_rate(rows, :first_attempt_pass_rate, attributable),
      total_tokens: round(Enum.sum(Enum.map(rows, &(&1.tokens.total * &1.run_count)))),
      agents: length(rows)
    }
  end

  # Σ(rate × attributable) / Σattributable — the fleet rate weighted by each agent's
  # attributable run count, NOT a mean of per-agent rates (which would weight a
  # one-run agent equal to a hundred-run one). 0.0 when nothing is attributable.
  @spec weighted_rate([map()], atom(), non_neg_integer()) :: float()
  defp weighted_rate(_rows, _key, 0), do: 0.0

  defp weighted_rate(rows, key, attributable) do
    Enum.sum(Enum.map(rows, &(Map.fetch!(&1, key) * (&1.run_count - &1.reviewer_flaked)))) /
      attributable
  end

  # The per-reviewer-adapter reliability ledger: each reviewer's rejection and
  # verdict-write (review_stuck) rates. Sorted worst-reliability-first so a
  # reviewer that flakes the mandatory verdict write surfaces at the top. A store
  # read error degrades to an empty ledger (the no-data state).
  @spec reviewer_rows() :: [map()]
  defp reviewer_rows do
    case ResultStore.aggregate_reviewer_reliability() do
      {:ok, ledger} ->
        ledger
        |> Enum.map(fn {reviewer, kpi} -> Map.put(kpi, :reviewer, reviewer) end)
        |> Enum.sort_by(&{&1.no_verdict_rate, &1.rejection_rate}, :desc)

      _error ->
        []
    end
  end

  @spec review_stuck_cause_rows() :: [map()]
  defp review_stuck_cause_rows do
    case ResultStore.aggregate_review_stuck_causes() do
      {:ok, causes} ->
        causes
        |> Enum.map(fn {cause, count} -> %{cause: cause, count: count} end)
        |> Enum.sort_by(&{-&1.count, to_string(&1.cause)})

      _error ->
        []
    end
  end

  @spec recovery_facts() :: AgentKPI.recovery_facts()
  defp recovery_facts do
    case ResultStore.aggregate_recovery_facts() do
      {:ok, facts} -> facts
      _error -> AgentKPI.aggregate_recovery_facts([])
    end
  end

  # Pivot the same per-agent facts by reviewer-assigned task facet, and read the
  # scout's per-facet verdict beside them. Both reads degrade to empty on error,
  # so a missing store / unwritten assessment renders the no-data state.
  @spec assign_facets(Socket.t()) :: Socket.t()
  defp assign_facets(socket) do
    facet_groups =
      case ResultStore.aggregate_by_facet() do
        {:ok, groups} -> groups
        _error -> []
      end

    assessment =
      case CapabilityScore.read_assessment(assessment_opts()) do
        {:ok, %Assessment{} = a} -> a
        _no_data_or_error -> nil
      end

    socket
    |> assign(:facets, build_facets(facet_groups, assessment))
    |> assign(:assessed_at, assessment && assessment.assessed_at)
  end

  # Production reads the scout artifact from `~/.harness` (CapabilityScore's
  # default, shared with the cron orchestrator + dispatch-recommend). An optional
  # `:facet_assessment_root` config relocates it — and lets tests inject one.
  @spec assessment_opts() :: keyword()
  defp assessment_opts do
    case Application.get_env(:harness, :facet_assessment_root) do
      nil -> []
      root -> [assessment_root: root]
    end
  end

  # One card per facet group: its label, the scout's verdict entry (or nil), and
  # the per-agent fact rows. Sorted by label so the layout is stable across reads.
  @spec build_facets([ResultStore.facet_group()], Assessment.t() | nil) :: [map()]
  defp build_facets(facet_groups, assessment) do
    verdicts = verdict_index(assessment)

    facet_groups
    |> Enum.map(fn %{facet: facet, agents: ledger} ->
      %{
        facet: facet,
        label: facet_label(facet),
        verdict: Map.get(verdicts, facet),
        agents: ledger |> to_rows() |> Enum.sort_by(& &1.run_count, :desc)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  # Index the scout's entries by normalized facet map (Elixir map keys are
  # order-independent, so this matches the grouped records' facets exactly).
  @spec verdict_index(Assessment.t() | nil) :: %{optional(map()) => Entry.t()}
  defp verdict_index(nil), do: %{}

  defp verdict_index(%Assessment{entries: entries}) do
    Map.new(entries, fn %Entry{} = entry -> {normalize_facet(entry.facet), entry} end)
  end

  @spec normalize_facet(term()) :: %{String.t() => term()}
  defp normalize_facet(facet) when is_map(facet) do
    facet
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_facet(_other), do: %{}

  @spec facet_label(map()) :: String.t()
  defp facet_label(facet) when map_size(facet) == 0, do: "Unfaceted"

  defp facet_label(facet) do
    facet
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {k, v} -> "#{k}=#{facet_value(v)}" end)
  end

  @spec facet_value(term()) :: String.t()
  defp facet_value(v) when is_binary(v), do: v
  defp facet_value(v) when is_number(v) or is_atom(v), do: to_string(v)
  defp facet_value(v), do: inspect(v)

  # Mean across an agent's reviewer-rating means — a single "reviewer quality"
  # number for the compact facet table. A mean of already-counted facts, not a
  # routing verdict (the scout writes that); nil when the diff was never rated.
  @spec quality(map()) :: float() | nil
  defp quality(row) do
    values = row |> row_ratings() |> Map.values() |> Enum.filter(&is_number/1)

    case values do
      [] -> nil
      _ -> Enum.sum(values) / length(values)
    end
  end

  @spec visible_facets([map()], String.t() | nil) :: [map()]
  defp visible_facets(facets, nil), do: facets
  defp visible_facets(facets, label), do: Enum.filter(facets, &(&1.label == label))

  @spec pill_class(String.t() | nil, String.t() | nil) :: String.t()
  defp pill_class(current, current), do: "facet-pill active"
  defp pill_class(_current, _target), do: "facet-pill"

  @spec winner_class(map(), Entry.t() | nil) :: String.t()
  defp winner_class(%{agent: agent}, %Entry{winner: agent}), do: "winner"
  defp winner_class(_row, _verdict), do: ""

  @spec format_ts(DateTime.t()) :: String.t()
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  # The union of rating keys across the ledger, sorted — one table column each.
  @spec rating_keys([map()]) :: [String.t()]
  defp rating_keys(rows) do
    rows
    |> Enum.flat_map(fn row -> Map.keys(row_ratings(row)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec row_ratings(map()) :: %{optional(String.t()) => float()}
  defp row_ratings(row), do: Map.get(row, :ratings) || %{}

  @spec to_rows(AgentKPI.t()) :: [map()]
  defp to_rows(ledger) do
    Enum.map(ledger, fn {agent, kpi} -> Map.put(kpi, :agent, agent) end)
  end

  # Clicking the active column flips its direction; selecting a new column starts
  # at :desc (the most-interesting-first default for every numeric KPI).
  @spec toggle_sort(Socket.t(), String.t()) :: Socket.t()
  defp toggle_sort(socket, col) do
    key = sort_key(col)
    flip? = socket.assigns.sort_by == key and socket.assigns.sort_dir == :desc

    socket
    |> assign(:sort_by, key)
    |> assign(:sort_dir, if(flip?, do: :asc, else: :desc))
  end

  # Rows whose sort value is nil (only cost_to_green, for an agent with zero
  # passes) always sink to the bottom regardless of direction — "no data" never
  # outranks a real number.
  @spec sort_rows([map()], atom(), :asc | :desc) :: [map()]
  defp sort_rows(rows, key, dir) do
    {present, missing} = Enum.split_with(rows, &(sort_value(&1, key) != nil))
    Enum.sort_by(present, &sort_value(&1, key), dir) ++ missing
  end

  @spec sort_value(map(), atom() | {:rating, String.t()}) :: term()
  defp sort_value(row, :agent), do: to_string(row.agent)
  defp sort_value(row, :tokens), do: row.tokens.total
  defp sort_value(row, {:rating, key}), do: Map.get(row_ratings(row), key)
  defp sort_value(row, key), do: Map.fetch!(row, key)

  @spec sort_key(String.t()) :: atom() | {:rating, String.t()}
  defp sort_key("agent"), do: :agent
  defp sort_key("run_count"), do: :run_count
  defp sort_key("reviewer_flaked"), do: :reviewer_flaked
  defp sort_key("success_rate"), do: :success_rate
  defp sort_key("first_attempt_pass_rate"), do: :first_attempt_pass_rate
  defp sort_key("review_iterations"), do: :review_iterations
  defp sort_key("tokens"), do: :tokens
  defp sort_key("cost_to_green"), do: :cost_to_green
  defp sort_key("rating:" <> key), do: {:rating, key}
  defp sort_key(_other), do: @default_sort

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="topbar">
      <strong>Agent KPIs</strong>
      <span class="count">{length(@rows)} agents</span>
      <a href="/harness">← All runs</a>
    </div>

    <p :if={@rows == []}>
      No run records yet — dispatch a task and its outcome will populate this ledger.
    </p>

    <div :if={@rows != []} class="kpi-strip">
      <div class="kpi-stat">
        <span class="kpi-stat-num">{format_count(@summary.total_runs)}</span>
        <span class="kpi-stat-label">Total runs</span>
      </div>
      <div class="kpi-stat">
        <span class="kpi-stat-num">{@summary.agents}</span>
        <span class="kpi-stat-label">Agents</span>
      </div>
      <div class="kpi-stat">
        <span class="kpi-stat-num tone-pass">{format_pct(@summary.success_rate)}</span>
        <span class="kpi-stat-label">Fleet success</span>
      </div>
      <div class="kpi-stat">
        <span class="kpi-stat-num tone-info">{format_pct(@summary.first_pass_rate)}</span>
        <span class="kpi-stat-label">First-try</span>
      </div>
      <div class="kpi-stat">
        <span class="kpi-stat-num">{format_count(@summary.total_tokens)}</span>
        <span class="kpi-stat-label">Total tokens</span>
      </div>
    </div>

    <nav :if={@rows != []} class="kpi-nav">
      <a href="#agents">Agents</a>
      <a :if={@reviewer_rows != []} href="#reviewers">Reviewers</a>
      <a :if={@review_stuck_cause_rows != []} href="#orchestration">Orchestration</a>
      <a :if={@recovery_facts.attempted_runs > 0} href="#recovery">Recovery</a>
      <a href="#facets">Facets</a>
    </nav>

    <section :if={@rows != []} id="agents" class="kpi-section">
      <div class="table-scroll">
        <table>
          <thead>
            <tr>
              <.sort_th col="agent" label="Agent" sort_by={@sort_by} sort_dir={@sort_dir} />
              <.sort_th col="run_count" label="Runs" sort_by={@sort_by} sort_dir={@sort_dir} />
              <.sort_th
                col="reviewer_flaked"
                label="Rvw flaked"
                sort_by={@sort_by}
                sort_dir={@sort_dir}
              />
              <.sort_th col="success_rate" label="Success" sort_by={@sort_by} sort_dir={@sort_dir} />
              <.sort_th
                col="first_attempt_pass_rate"
                label="First-try"
                sort_by={@sort_by}
                sort_dir={@sort_dir}
              />
              <.sort_th
                col="review_iterations"
                label="Reviews"
                sort_by={@sort_by}
                sort_dir={@sort_dir}
              />
              <.sort_th col="tokens" label="Mean tokens" sort_by={@sort_by} sort_dir={@sort_dir} />
              <.sort_th
                col="cost_to_green"
                label="Cost→green"
                sort_by={@sort_by}
                sort_dir={@sort_dir}
              />
              <.sort_th
                :for={key <- @rating_keys}
                col={"rating:#{key}"}
                label={rating_label(key)}
                sort_by={@sort_by}
                sort_dir={@sort_dir}
              />
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td><code>{row.agent || "—"}</code></td>
              <td>{row.run_count}</td>
              <td>{row.reviewer_flaked}</td>
              <.rate_cell value={row.success_rate} tone={:pass} />
              <.rate_cell value={row.first_attempt_pass_rate} tone={:info} />
              <td>{format_float(row.review_iterations)}</td>
              <td>{format_count(row.tokens.total)}</td>
              <td>{format_count(row.cost_to_green)}</td>
              <td :for={key <- @rating_keys}>{format_rating(Map.get(row_ratings(row), key))}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section :if={@reviewer_rows != []} id="reviewers" class="kpi-section">
      <div class="topbar">
        <strong>Reviewer reliability</strong>
        <span class="count">{length(@reviewer_rows)} reviewers</span>
      </div>

      <table>
        <thead>
          <tr>
            <th>Reviewer</th>
            <th>Gated</th>
            <th>Rejections</th>
            <th>Reject rate</th>
            <th>No verdict</th>
            <th>No-verdict rate</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @reviewer_rows}>
            <td><code>{inspect(row.reviewer)}</code></td>
            <td>{row.reviewed_count}</td>
            <td>{row.rejection_count}</td>
            <.rate_cell value={row.rejection_rate} tone={:warn} />
            <td>{row.no_verdict_count}</td>
            <.rate_cell value={row.no_verdict_rate} tone={:warn} />
          </tr>
        </tbody>
      </table>
    </section>

    <section :if={@review_stuck_cause_rows != []} id="orchestration" class="kpi-section">
      <div class="topbar">
        <strong>Orchestration health</strong>
        <span class="count">review_stuck by cause</span>
      </div>

      <p>
        Selection/no-reviewer stuck runs are counted here, not in reviewer reliability.
      </p>

      <table>
        <thead>
          <tr>
            <th>Cause</th>
            <th>Count</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @review_stuck_cause_rows}>
            <td><code>{row.cause}</code></td>
            <td>{row.count}</td>
          </tr>
        </tbody>
      </table>
    </section>

    <section :if={@recovery_facts.attempted_runs > 0} id="recovery" class="kpi-section">
      <div class="topbar">
        <strong>Recovery facts</strong>
        <span class="count">{@recovery_facts.attempted_runs} recovered runs</span>
      </div>

      <table>
        <thead>
          <tr>
            <th>Runs</th>
            <th>Attempts</th>
            <th>Repaired</th>
            <th>Dead</th>
            <th>Masked-failure rate</th>
            <th>Recovery token cost</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{@recovery_facts.attempted_runs}</td>
            <td>{@recovery_facts.total_attempts}</td>
            <td>{@recovery_facts.repaired_runs}</td>
            <td>{@recovery_facts.dead_runs}</td>
            <.rate_cell value={@recovery_facts.masked_failure_rate} tone={:warn} />
            <td>{format_count(@recovery_facts.tokens.total)}</td>
          </tr>
        </tbody>
      </table>

      <table>
        <thead>
          <tr>
            <th>Run</th>
            <th>Task</th>
            <th>Agent</th>
            <th>Attempts</th>
            <th>Outcome</th>
            <th>Repaired</th>
            <th>Tokens</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @recovery_facts.per_run}>
            <td><code>{row.run_id}</code></td>
            <td><code>{row.task_id}</code></td>
            <td><code>{row.agent || "—"}</code></td>
            <td>{row.attempts}</td>
            <td><code>{row.outcome || "—"}</code></td>
            <td>{row.repaired || "—"}</td>
            <td>{format_count(row.tokens.total)}</td>
          </tr>
        </tbody>
      </table>
    </section>

    <section id="facets" class="kpi-section">
      <div class="topbar">
        <strong>By task-facet</strong>
        <span class="count">{length(@facets)} facet groups</span>
        <span :if={@assessed_at} class="count">scout assessed {format_ts(@assessed_at)}</span>
      </div>

      <p :if={@facets == []}>
        No faceted records yet — the reviewer assigns task facets in <code>review.json</code>;
        they appear here once runs settle.
      </p>

      <div :if={@facets != []} class="facet-filter">
        <button
          type="button"
          class={pill_class(@facet_filter, nil)}
          phx-click="facet"
          phx-value-key=""
        >
          All
        </button>
        <button
          :for={facet <- @facets}
          type="button"
          class={pill_class(@facet_filter, facet.label)}
          phx-click="facet"
          phx-value-key={facet.label}
        >
          {facet.label}
        </button>
      </div>

      <div :for={facet <- visible_facets(@facets, @facet_filter)} class="facet-card">
        <div class="facet-head">
          <strong>{facet.label}</strong>
          <span :if={facet.verdict} class="scout-winner">
            scout → <code>{facet.verdict.winner}</code>
          </span>
          <span :if={is_nil(facet.verdict)} class="count">no scout verdict yet</span>
        </div>
        <p :if={facet.verdict} class="scout-reasoning">{facet.verdict.reasoning}</p>

        <table>
          <thead>
            <tr>
              <th>Agent</th>
              <th>Runs</th>
              <th>Approve</th>
              <th>First-try</th>
              <th>Quality</th>
              <th>Mean tokens</th>
              <th>Cost→green</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- facet.agents} class={winner_class(row, facet.verdict)}>
              <td><code>{row.agent || "—"}</code></td>
              <td>{row.run_count}</td>
              <.rate_cell value={row.success_rate} tone={:pass} />
              <.rate_cell value={row.first_attempt_pass_rate} tone={:info} />
              <td>{format_rating(quality(row))}</td>
              <td>{format_count(row.tokens.total)}</td>
              <td>{format_count(row.cost_to_green)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr(:col, :string, required: true)
  attr(:label, :string, required: true)
  attr(:sort_by, :atom, required: true)
  attr(:sort_dir, :atom, required: true)

  # A clickable column header. The active column carries a direction arrow so the
  # current sort is legible; clicking re-sorts (toggling direction on re-click).
  @spec sort_th(map()) :: Rendered.t()
  defp sort_th(assigns) do
    ~H"""
    <th>
      <button type="button" class="sort-th" phx-click="sort" phx-value-col={@col}>
        {@label}{sort_arrow(@col, @sort_by, @sort_dir)}
      </button>
    </th>
    """
  end

  @spec sort_arrow(String.t(), atom(), :asc | :desc) :: String.t()
  defp sort_arrow(col, sort_by, dir) do
    cond do
      sort_key(col) != sort_by -> ""
      dir == :asc -> " ▲"
      true -> " ▼"
    end
  end

  attr(:value, :float, required: true)
  attr(:tone, :atom, default: :pass)

  # A rate cell: the percentage label beside a proportion bar whose fill width IS
  # the value. `tone` is a per-column constant that only picks the fill colour — it
  # is never derived from the value, so the bar encodes the count without judging it.
  @spec rate_cell(map()) :: Rendered.t()
  defp rate_cell(assigns) do
    ~H"""
    <td>
      <div class="kpi-cell">
        <span class="kpi-pct">{format_pct(@value)}</span>
        <span class="kpi-bar">
          <span class={"kpi-bar-fill tone-#{@tone}"} style={"width: #{bar_pct(@value)}%"}></span>
        </span>
      </div>
    </td>
    """
  end

  # Clamp a 0.0–1.0 rate to an integer 0–100 for a CSS bar width; nil → 0 (empty bar).
  @spec bar_pct(number() | nil) :: non_neg_integer()
  defp bar_pct(nil), do: 0
  defp bar_pct(value), do: value |> Kernel.*(100) |> round() |> max(0) |> min(100)

  @spec format_pct(float()) :: String.t()
  defp format_pct(rate), do: "#{round(rate * 100)}%"

  @spec format_float(number()) :: String.t()
  defp format_float(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  @spec format_count(number() | nil) :: String.t()
  defp format_count(nil), do: "—"
  defp format_count(value), do: value |> round() |> Integer.to_string() |> delimit()

  # A reviewer rating mean (e.g. 8.0); an agent never rated on this key shows a dash.
  @spec format_rating(number() | nil) :: String.t()
  defp format_rating(nil), do: "—"
  defp format_rating(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  # Humanize a free-form rating key for the column header (code_quality → "Code quality").
  @spec rating_label(String.t()) :: String.t()
  defp rating_label(key) do
    key |> String.replace("_", " ") |> String.capitalize()
  end

  # Group an integer string into thousands so a 27M-token count reads at a glance.
  @spec delimit(String.t()) :: String.t()
  defp delimit(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
