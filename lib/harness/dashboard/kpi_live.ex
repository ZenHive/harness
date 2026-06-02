defmodule Harness.Dashboard.KPILive do
  @moduledoc """
  Per-agent KPI ledger LiveView (Task 115).

  Renders `Harness.ResultStore.aggregate_by_agent/0` over every persisted run
  record as a
  sortable per-agent table: run count, success rate, first-attempt-pass rate,
  mean repair attempts, mean tokens, and cost-to-green. This is the at-a-glance
  *trust ledger* — the question "what is each agent's track record across all
  runs?" answered in one view, closing the user's stated gap (we had the data via
  `Harness.AgentKPI` but no way to see it at once).

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
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.AgentKPI
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
     |> assign_rows()}
  end

  # Only a settled run mints a new LogRecord, so it is the only event that can
  # move the aggregates; in-flight updates are ignored to avoid needless re-reads.
  @impl Phoenix.LiveView
  def handle_info({:harness_run_settled, %Status{}}, socket) do
    {:noreply, assign_rows(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("sort", %{"col" => col}, socket) do
    {:noreply, socket |> toggle_sort(col) |> assign_rows()}
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

    assign(socket, :rows, sort_rows(rows, socket.assigns.sort_by, socket.assigns.sort_dir))
  end

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

  @spec sort_value(map(), atom()) :: term()
  defp sort_value(row, :agent), do: to_string(row.agent)
  defp sort_value(row, :tokens), do: row.tokens.total
  defp sort_value(row, key), do: Map.fetch!(row, key)

  @spec sort_key(String.t()) :: atom()
  defp sort_key("agent"), do: :agent
  defp sort_key("run_count"), do: :run_count
  defp sort_key("success_rate"), do: :success_rate
  defp sort_key("first_attempt_pass_rate"), do: :first_attempt_pass_rate
  defp sort_key("review_iterations"), do: :review_iterations
  defp sort_key("tokens"), do: :tokens
  defp sort_key("cost_to_green"), do: :cost_to_green
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

    <table :if={@rows != []}>
      <thead>
        <tr>
          <.sort_th col="agent" label="Agent" sort_by={@sort_by} sort_dir={@sort_dir} />
          <.sort_th col="run_count" label="Runs" sort_by={@sort_by} sort_dir={@sort_dir} />
          <.sort_th col="success_rate" label="Success" sort_by={@sort_by} sort_dir={@sort_dir} />
          <.sort_th
            col="first_attempt_pass_rate"
            label="First-try"
            sort_by={@sort_by}
            sort_dir={@sort_dir}
          />
          <.sort_th col="review_iterations" label="Reviews" sort_by={@sort_by} sort_dir={@sort_dir} />
          <.sort_th col="tokens" label="Mean tokens" sort_by={@sort_by} sort_dir={@sort_dir} />
          <.sort_th col="cost_to_green" label="Cost→green" sort_by={@sort_by} sort_dir={@sort_dir} />
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <td><code>{row.agent || "—"}</code></td>
          <td>{row.run_count}</td>
          <td>{format_pct(row.success_rate)}</td>
          <td>{format_pct(row.first_attempt_pass_rate)}</td>
          <td>{format_float(row.review_iterations)}</td>
          <td>{format_count(row.tokens.total)}</td>
          <td>{format_count(row.cost_to_green)}</td>
        </tr>
      </tbody>
    </table>
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

  @spec format_pct(float()) :: String.t()
  defp format_pct(rate), do: "#{round(rate * 100)}%"

  @spec format_float(number()) :: String.t()
  defp format_float(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  @spec format_count(number() | nil) :: String.t()
  defp format_count(nil), do: "—"
  defp format_count(value), do: value |> round() |> Integer.to_string() |> delimit()

  # Group an integer string into thousands so a 27M-token count reads at a glance.
  @spec delimit(String.t()) :: String.t()
  defp delimit(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
