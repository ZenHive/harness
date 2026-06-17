defmodule Harness.Dashboard.Components do
  @moduledoc """
  Shared function components for the harness dashboard (Task 85).

  Two layers under one module:

    * **Chrome** — `page_shell/1`, `navbar/1`, `footer/1`, `bucket_badge/1`.
      The persistent navbar + footer wrap every dashboard page via the root
      layout calling `<.page_shell>` around `{@inner_content}`.

    * **Chat-style turns** — `message_row/1`, `tool_call/1`, `json_tree/1`,
      `json_node/1` (with `value_kind/1` + `role_label/1` helpers). Extracted
      verbatim from `Harness.Dashboard.ChatLive` so the same vocabulary can
      be reused by Task 87's `<.transcript_view>` on the run-detail page.

  All public components declare arguments via `attr/3` and slots via `slot/3`
  (Phoenix 1.8 / LiveView 1.1 modern style). HEEx `:if` / `:for` only; no
  `Phoenix.HTML.raw/1` on string-interpolated content.

  ## Font sourcing (Task 85 decision)

  The mpp.dev-inspired plan called for Geist Sans + Geist Mono + Geist Pixel
  Square. The first two are reliable via npm/jsdelivr and are loaded by
  `Harness.Dashboard.Tokens.stylesheet/1`. The pixel variant is mpp.dev's
  brand-custom typeface — not publicly distributed. The dashboard wordmark
  in `navbar/1` uses Geist Sans with tracking + lowercase styling instead;
  this decision is settled and should not be revisited without a new font
  source.
  """

  use Phoenix.Component

  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Run.Status
  alias Harness.SettingsStore
  alias Phoenix.LiveView.Rendered

  @system_snippet_chars 160

  ## --- Chrome ---------------------------------------------------------------

  slot(:inner_block, required: true)

  @doc """
  Wraps every dashboard page with the persistent navbar + main + footer.

  Called once from `root.html.heex` around `{@inner_content}`. Each page's
  own LiveView render only emits its page-level content; the chrome stays
  identical across `/harness`, `/harness/runs/:id`, `/harness/chat`, and
  `/harness/chat/:session_id`.
  """
  @spec page_shell(map()) :: Rendered.t()
  def page_shell(assigns) do
    ~H"""
    <div class="page-shell">
      <.navbar />
      <main class="page-main">
        <.operator_flash />
        {render_slot(@inner_block)}
      </main>
      <.footer />
    </div>
    """
  end

  @doc """
  Persistent top navigation bar.

  Brand wordmark on the left, page links on the right. Active-state marking
  was deliberately omitted from the v0_8 first pass — Phoenix LiveView's
  root layout doesn't have access to socket assigns, so threading
  `current_path` would require either a conn-pipeline plug or the app
  layout, neither of which earns the complexity for a hover-styling decoration.
  """
  @spec navbar(map()) :: Rendered.t()
  def navbar(assigns) do
    ~H"""
    <header class="navbar">
      <a class="navbar-brand" href="/harness">
        <span class="brand-mark">harness</span>
      </a>
      <nav class="navbar-links" aria-label="Primary">
        <a href="/harness">Dashboard</a>
        <a href="/harness/roadmap">Roadmap</a>
        <a href="/harness/compare">Compare</a>
        <a href="/harness/projects/explore">Explore</a>
        <a href="/harness/chat">Chat</a>
        <a href="/harness/settings">Settings</a>
        <a href="/harness/oban">Oban</a>
      </nav>
    </header>
    """
  end

  @doc """
  Persistent bottom chrome.

  Intentionally minimal: brand wordmark + a one-line tagline. Page content
  carries the real density; the footer is the visual stop.
  """
  @spec footer(map()) :: Rendered.t()
  def footer(assigns) do
    ~H"""
    <footer class="page-footer">
      <span class="footer-mark">harness</span>
      <span class="footer-tag">OTP-native task execution · localhost:4018</span>
    </footer>
    """
  end

  attr(:bucket, :atom, values: [:in_flight, :repairing, :green, :red], required: true)
  attr(:label, :string, default: nil)

  @doc """
  Typed badge for a run bucket — the dashboard's verdict signal.

  Each bucket carries a leading glyph (`◯ ⟳ ● ✗`) so the badge is readable
  even with CSS off. `:label` overrides the default bucket name.
  """
  @spec bucket_badge(map()) :: Rendered.t()
  def bucket_badge(assigns) do
    assigns =
      assigns
      |> assign(:label, assigns.label || Atom.to_string(assigns.bucket))
      |> assign(:glyph, bucket_glyph(assigns.bucket))

    ~H"""
    <span class={"bucket bucket-#{@bucket}"} data-bucket={@bucket}>
      <span class="bucket-glyph" aria-hidden="true">{@glyph}</span>
      <span class="bucket-label">{@label}</span>
    </span>
    """
  end

  attr(:notice, :any, default: nil)
  attr(:include_persistent, :boolean, default: true)

  @doc """
  Shared dashboard flash surface for operator notices.

  Persistent notices are derived from live runtime state, such as the no-op
  settings store. LiveViews pass transient `{kind, message}` tuples for event
  feedback and keep the markup here.
  """
  @spec operator_flash(map()) :: Rendered.t()
  def operator_flash(assigns) do
    assigns = assign(assigns, :notices, operator_notices(assigns.notice, assigns.include_persistent))

    ~H"""
    <div :if={@notices != []} class="operator-flash" role="status" aria-live="polite">
      <div
        :for={notice <- @notices}
        class="operator-notice"
        data-kind={notice.kind}
        data-persistent={to_string(notice.persistent?)}
      >
        {notice.message}
      </div>
    </div>
    """
  end

  ## --- Chat-style turns -----------------------------------------------------

  attr(:dom_id, :string, required: true)
  attr(:role, :atom, values: [:user, :assistant, :tool, :terminal], required: true)
  attr(:text, :string, default: "")
  attr(:streaming?, :boolean, default: false)
  attr(:tool_calls, :list, default: [])

  @doc """
  One chat-style turn (user / assistant / tool / terminal).

  The DOM id stays stable across stream updates so streamed token chunks
  replace the same element in place. `tool_calls` renders as collapsible
  `<.tool_call>` blocks under the message body.
  """
  @spec message_row(map()) :: Rendered.t()
  def message_row(assigns) do
    ~H"""
    <article id={@dom_id} class={"msg msg-#{@role}"}>
      <div class="msg-role">{role_label(@role)}</div>
      <div class="msg-content">
        <div class="msg-body" data-streaming={if @streaming?, do: "true", else: "false"}>{@text}</div>
        <.tool_call
          :for={tc <- @tool_calls}
          id={tc.id}
          name={tc.name}
          args={tc.args}
          result={tc.result}
          status={tc.status}
        />
      </div>
    </article>
    """
  end

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:args, :any, required: true)
  attr(:result, :any, default: nil)
  attr(:status, :atom, values: [:pending, :done], default: :pending)

  @doc """
  Collapsible block representing a single tool invocation.

  Native `<details>` (no JS). Arguments and result render through the
  structured `<.json_tree>` walker; the LLM-supplied payload never reaches
  `Phoenix.HTML.raw/1`.
  """
  @spec tool_call(map()) :: Rendered.t()
  def tool_call(assigns) do
    ~H"""
    <details class="tool-call">
      <summary>
        <span class="tool-name">{@name}</span>
        <span class="tool-status" data-status={@status}>{@status}</span>
      </summary>
      <div class="tool-body">
        <div class="tool-section">
          <div class="tool-section-label">arguments</div>
          <.json_tree value={@args} />
        </div>
        <div :if={@result != nil} class="tool-section">
          <div class="tool-section-label">result</div>
          <.json_tree value={@result} />
        </div>
      </div>
    </details>
    """
  end

  attr(:value, :any, required: true)

  @doc """
  Recursive structured JSON renderer.

  Pattern-matches on value type and emits `<dl>` / `<ol>` / typed leaf
  spans — never inspects to a string + `raw/1`s into a `<pre>`. Empty maps
  and lists render as `{}` / `[]` placeholders.
  """
  @spec json_tree(map()) :: Rendered.t()
  def json_tree(%{value: value} = assigns) do
    assigns = assign(assigns, :kind, value_kind(value))

    ~H"""
    <div class="jtree">
      <.json_node value={@value} kind={@kind} />
    </div>
    """
  end

  attr(:value, :any, required: true)
  attr(:kind, :atom, required: true)

  @doc false
  @spec json_node(map()) :: Rendered.t()
  def json_node(%{kind: :map, value: value} = assigns) do
    pairs =
      value
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(fn {k, _} -> k end)

    assigns = assign(assigns, :pairs, pairs)

    ~H"""
    <dl :if={@pairs != []}>
      <div :for={{key, val} <- @pairs}>
        <dt>{key}</dt>
        <dd><.json_node value={val} kind={value_kind(val)} /></dd>
      </div>
    </dl>
    <span :if={@pairs == []} class="empty">{"{}"}</span>
    """
  end

  def json_node(%{kind: :list, value: value} = assigns) do
    items = Enum.with_index(value)
    assigns = assign(assigns, :items, items)

    ~H"""
    <ol :if={@items != []}>
      <li :for={{item, _i} <- @items}>
        <.json_node value={item} kind={value_kind(item)} />
      </li>
    </ol>
    <span :if={@items == []} class="empty">{"[]"}</span>
    """
  end

  def json_node(%{kind: :string, value: value} = assigns) do
    assigns = assign(assigns, :text, value)

    ~H"""
    <span class="leaf-string">"{@text}"</span>
    """
  end

  def json_node(%{kind: :number, value: value} = assigns) do
    assigns = assign(assigns, :n, value)

    ~H"""
    <span class="leaf-number">{@n}</span>
    """
  end

  def json_node(%{kind: :boolean, value: value} = assigns) do
    assigns = assign(assigns, :b, value)

    ~H"""
    <span class="leaf-bool">{to_string(@b)}</span>
    """
  end

  def json_node(%{kind: :atom, value: value} = assigns) do
    assigns = assign(assigns, :a, value)

    ~H"""
    <span class="leaf-atom">:{@a}</span>
    """
  end

  def json_node(%{kind: :nil_, value: _value} = assigns) do
    ~H"""
    <span class="leaf-nil">null</span>
    """
  end

  def json_node(%{kind: :other, value: value} = assigns) do
    assigns = assign(assigns, :inspected, inspect(value))

    ~H"""
    <span class="leaf-other">{@inspected}</span>
    """
  end

  ## --- Run detail header (Task 312) ----------------------------------------

  @base_run_stages [:dispatched, :running, :committing, :reviewing]
  @milliseconds_per_second 1_000
  @seconds_per_minute 60
  @minutes_per_hour 60

  attr(:state, :atom, required: true)

  @doc """
  Horizontal pipeline for `Harness.Run.Status.state` on the run-detail page.

  Renders dispatched → running → committing → reviewing → done/failed as a
  mechanical fact; `:recovering` / `:held` steps appear only while the run is
  in those states. Landing and audit are post-settle workers — not stages here.
  """
  @spec stage_stepper(map()) :: Rendered.t()
  def stage_stepper(assigns) do
    steps = stage_stepper_steps(assigns.state)
    assigns = assign(assigns, :steps, steps)

    ~H"""
    <ol class="run-stage-stepper" data-run-stage-stepper aria-label="Run stage">
      <li :for={{step, idx} <- Enum.with_index(@steps)} class={stepper_step_class(step.status)}>
        <span :if={idx > 0} class="run-stage-sep" aria-hidden="true">→</span>
        <span class="run-stage-label" data-stage={step.stage} data-status={step.status}>
          {step.label}
        </span>
      </li>
    </ol>
    """
  end

  @doc false
  @spec stage_stepper_steps(Status.state()) :: [
          %{stage: Status.state(), label: String.t(), status: :complete | :current | :future}
        ]
  def stage_stepper_steps(state) do
    stages = stages_for(state)
    current_idx = Enum.find_index(stages, &(&1 == state)) || 0

    Enum.map(stages, fn stage ->
      %{
        stage: stage,
        label: stage_label(stage),
        status: step_status(current_idx, stages, stage)
      }
    end)
  end

  @spec stages_for(Status.state()) :: [Status.state()]
  defp stages_for(:recovering), do: [:dispatched, :running, :recovering, :committing, :reviewing]

  defp stages_for(:held), do: [:dispatched, :running, :held, :committing, :reviewing]

  defp stages_for(:done), do: @base_run_stages ++ [:done]
  defp stages_for(:failed), do: @base_run_stages ++ [:failed]
  defp stages_for(_state), do: @base_run_stages

  @spec stage_label(Status.state()) :: String.t()
  defp stage_label(:dispatched), do: "Dispatched"
  defp stage_label(:running), do: "Running"
  defp stage_label(:committing), do: "Committing"
  defp stage_label(:reviewing), do: "Reviewing"
  defp stage_label(:recovering), do: "Recovering"
  defp stage_label(:held), do: "Held"
  defp stage_label(:done), do: "Done"
  defp stage_label(:failed), do: "Failed"

  @spec step_status(non_neg_integer(), [Status.state()], Status.state()) ::
          :complete | :current | :future
  defp step_status(current_idx, stages, stage) do
    idx = Enum.find_index(stages, &(&1 == stage))

    cond do
      idx == current_idx -> :current
      idx < current_idx -> :complete
      true -> :future
    end
  end

  @spec stepper_step_class(:complete | :current | :future) :: String.t()
  defp stepper_step_class(:complete), do: "run-stage-step run-stage-step-complete"
  defp stepper_step_class(:current), do: "run-stage-step run-stage-step-current"
  defp stepper_step_class(:future), do: "run-stage-step run-stage-step-future"

  attr(:status, :map, required: true)
  attr(:now, :any, required: true)

  @doc """
  Renders run lifecycle timing facts for the run-detail header.
  """
  @spec run_timing(map()) :: Rendered.t()
  def run_timing(assigns) do
    status = assigns.status
    now = assigns.now

    assigns =
      assigns
      |> assign(:elapsed, elapsed_label(status, now))
      |> assign(:current_stage, current_stage_label(status, now))
      |> assign(:stage_durations, stage_duration_rows(status, now))

    ~H"""
    <dt>Elapsed</dt>
    <dd data-run-elapsed>{@elapsed}</dd>
    <dt>Current stage</dt>
    <dd data-run-current-stage>{@current_stage}</dd>
    <dt :if={@stage_durations != []}>Stage durations</dt>
    <dd :if={@stage_durations != []} data-run-stage-durations>
      <span :for={entry <- @stage_durations} class="config-pill" data-stage={entry.stage}>
        {entry.label}: {entry.duration}
      </span>
    </dd>
    """
  end

  @doc false
  @spec elapsed_label(Status.t(), DateTime.t()) :: String.t()
  def elapsed_label(%Status{started_at: nil}, _now), do: "—"

  def elapsed_label(%Status{started_at: %DateTime{} = started_at} = status, %DateTime{} = now) do
    status
    |> elapsed_end_at(now)
    |> duration_between(started_at)
    |> duration_label()
  end

  @doc false
  @spec current_stage_label(Status.t(), DateTime.t()) :: String.t()
  def current_stage_label(%Status{state: state} = status, now) do
    duration =
      case state_duration_ms(status, state, now) do
        nil -> "—"
        ms -> duration_label(ms)
      end

    "#{stage_label(state)} · #{duration}"
  end

  @doc false
  @spec stage_duration_rows(Status.t(), DateTime.t()) :: [
          %{stage: Status.state(), label: String.t(), duration: String.t()}
        ]
  def stage_duration_rows(%Status{} = status, %DateTime{} = now) do
    stages = stages_for(status.state)
    timestamps = Enum.map(stages, fn stage -> {stage, entered_at(status, stage)} end)

    timestamps
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{stage, %DateTime{} = started_at}, index} ->
        case stage_end_at(status, timestamps, index, now) do
          %DateTime{} = ended_at ->
            duration = ended_at |> duration_between(started_at) |> duration_label()
            [%{stage: stage, label: stage_label(stage), duration: duration}]

          nil ->
            []
        end

      {_entry, _index} ->
        []
    end)
  end

  @spec elapsed_end_at(Status.t(), DateTime.t()) :: DateTime.t()
  defp elapsed_end_at(%Status{state: state} = status, now) when state in [:done, :failed] do
    entered_at(status, state) || now
  end

  defp elapsed_end_at(_status, now), do: now

  @spec state_duration_ms(Status.t(), Status.state(), DateTime.t()) :: non_neg_integer() | nil
  defp state_duration_ms(%Status{state: state}, stage, _now) when state in [:done, :failed] and stage == state, do: nil

  defp state_duration_ms(%Status{} = status, stage, now) do
    with %DateTime{} = started_at <- entered_at(status, stage),
         %DateTime{} = ended_at <- state_end_at(status, stage, now) do
      duration_between(ended_at, started_at)
    end
  end

  @spec state_end_at(Status.t(), Status.state(), DateTime.t()) :: DateTime.t() | nil
  defp state_end_at(%Status{state: stage} = status, stage, now), do: elapsed_end_at(status, now)

  defp state_end_at(%Status{} = status, stage, _now) do
    stages = stages_for(status.state)
    timestamps = Enum.map(stages, fn known_stage -> {known_stage, entered_at(status, known_stage)} end)
    index = Enum.find_index(stages, &(&1 == stage))

    if index, do: next_entered_at(timestamps, index)
  end

  @spec stage_end_at(Status.t(), [{Status.state(), DateTime.t() | nil}], non_neg_integer(), DateTime.t()) ::
          DateTime.t() | nil
  defp stage_end_at(%Status{} = status, timestamps, index, now) do
    next_entered_at(timestamps, index) || current_stage_end(status, Enum.at(timestamps, index), now)
  end

  @spec current_stage_end(Status.t(), {Status.state(), DateTime.t() | nil} | nil, DateTime.t()) :: DateTime.t() | nil
  defp current_stage_end(%Status{state: state} = status, {state, %DateTime{}}, now), do: elapsed_end_at(status, now)
  defp current_stage_end(_status, _entry, _now), do: nil

  @spec next_entered_at([{Status.state(), DateTime.t() | nil}], non_neg_integer()) :: DateTime.t() | nil
  defp next_entered_at(timestamps, index) do
    timestamps
    |> Enum.drop(index + 1)
    |> Enum.find_value(fn
      {_stage, %DateTime{} = entered_at} -> entered_at
      _entry -> nil
    end)
  end

  @spec entered_at(Status.t(), Status.state()) :: DateTime.t() | nil
  defp entered_at(%Status{state_entered_at: entered_at}, state) when is_map(entered_at) do
    Map.get(entered_at, state) || Map.get(entered_at, Atom.to_string(state))
  end

  defp entered_at(_status, _state), do: nil

  @spec duration_between(DateTime.t(), DateTime.t()) :: non_neg_integer()
  defp duration_between(%DateTime{} = ended_at, %DateTime{} = started_at) do
    max(0, DateTime.diff(ended_at, started_at, :millisecond))
  end

  @spec duration_label(non_neg_integer()) :: String.t()
  defp duration_label(ms) when ms < @milliseconds_per_second, do: "<1s"

  defp duration_label(ms) do
    total_seconds = div(ms, @milliseconds_per_second)
    minutes = div(total_seconds, @seconds_per_minute)
    seconds = rem(total_seconds, @seconds_per_minute)
    hours = div(minutes, @minutes_per_hour)
    minutes = rem(minutes, @minutes_per_hour)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{seconds}s"
      true -> "#{seconds}s"
    end
  end

  ## --- Live transcript chrome (Task 314) ------------------------------------

  attr(:events, :list, required: true)
  attr(:agent, :atom, required: true)
  attr(:last_event_at, :any, default: nil)
  attr(:now, :any, required: true)
  attr(:live, :boolean, default: false)

  @doc """
  Summary, current-activity, and last-output heartbeat above the transcript.

  Counts turns / tool calls / files from the parsed event list; relays the
  latest tool call in plain language; ticks last-event age via `now` (no stuck
  verdict). Pure — `attr/3` + HEEx only.
  """
  @spec transcript_chrome(map()) :: Rendered.t()
  def transcript_chrome(assigns) do
    summary = transcript_summary_label(assigns.events, assigns.agent)
    activity = current_activity_label(assigns.events)
    heartbeat = last_output_age_label(assigns.last_event_at, assigns.now)
    show_heartbeat = assigns.live && heartbeat != nil

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:activity, activity)
      |> assign(:heartbeat, heartbeat)
      |> assign(:show_heartbeat, show_heartbeat)

    ~H"""
    <div class="transcript-chrome" data-transcript-chrome>
      <p class="transcript-summary" data-transcript-summary>{@summary}</p>
      <p :if={@activity} class="transcript-activity" data-transcript-activity>{@activity}</p>
      <p :if={@show_heartbeat} class="transcript-heartbeat" data-transcript-heartbeat>
        last output {@heartbeat}
      </p>
    </div>
    """
  end

  @doc false
  @spec transcript_summary_label([Parser.event()], Parser.agent_kind()) :: String.t()
  def transcript_summary_label(events, agent) do
    counts = transcript_counts(events, agent)

    "#{counts.turns} turns · #{counts.tool_calls} tool calls · #{counts.files} files"
  end

  @doc false
  @spec transcript_counts([Parser.event()], Parser.agent_kind()) :: %{
          turns: non_neg_integer(),
          tool_calls: non_neg_integer(),
          files: non_neg_integer()
        }
  def transcript_counts(events, agent) do
    %{
      turns: turn_count(events, agent),
      tool_calls: tool_call_count(events),
      files: length(edited_file_stats(events))
    }
  end

  @doc false
  @spec turn_count([Parser.event()], Parser.agent_kind()) :: non_neg_integer()
  def turn_count(events, agent) do
    events
    |> group_events(agent)
    |> Enum.count(&(&1.kind == :assistant_message))
  end

  @doc false
  @spec tool_call_count([Parser.event()]) :: non_neg_integer()
  def tool_call_count(events) do
    Enum.count(events, &match?({:assistant_tool_use, _}, &1))
  end

  @doc false
  @spec current_activity_label([Parser.event()]) :: String.t() | nil
  def current_activity_label(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:assistant_tool_use, tool_use} -> activity_phrase(tool_use)
      _other -> nil
    end)
  end

  @doc false
  @spec last_output_age_label(DateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def last_output_age_label(nil, _now), do: nil

  def last_output_age_label(%DateTime{} = last_at, %DateTime{} = now) do
    seconds = max(0, DateTime.diff(now, last_at, :millisecond)) |> div(@milliseconds_per_second)

    if seconds < 1 do
      "<1s ago"
    else
      "#{seconds}s ago"
    end
  end

  @doc false
  @spec edited_file_stats([Parser.event()]) :: [
          %{path: String.t(), added: non_neg_integer(), deleted: non_neg_integer(), edits: non_neg_integer()}
        ]
  def edited_file_stats(events) do
    events
    |> Enum.reduce({[], %{}}, &accumulate_file_stat/2)
    |> then(fn {order, stats} ->
      Enum.map(order, fn path -> Map.put(stats[path], :path, path) end)
    end)
  end

  ## --- Changed files / run diff --------------------------------------------

  attr(:files, :list, default: [])

  @doc """
  In-progress edited-file list for a *live* run.

  A live run has no commit yet, so the change signal comes from the agent's
  own file-editing tool calls (extracted upstream from the parsed transcript
  events). Renders each path as a chip with per-file +/- line counts (or an
  edit-count when line deltas are unavailable). An empty list shows a waiting
  note. Pure — `attr/3` + HEEx only.
  """
  @spec edited_files_live(map()) :: Rendered.t()
  def edited_files_live(assigns) do
    ~H"""
    <section class="changed-files changed-files-live">
      <header class="cf-head">
        <span class="cf-title">Files being edited</span>
        <span class="cf-live-tag" aria-label="run in progress">
          <span class="cf-live-dot" aria-hidden="true"></span>live
        </span>
      </header>
      <p :if={@files == []} class="cf-empty">No file edits observed yet.</p>
      <ul :if={@files != []} class="cf-chips">
        <li :for={file <- @files} class="cf-chip" data-file-path={file.path}>
          <.file_path path={file.path} />
          <span
            :if={file.added > 0 or file.deleted > 0}
            class="cf-file-counts"
            data-file-delta
          >
            <span :if={file.added > 0} class="cf-add">+{file.added}</span>
            <span :if={file.deleted > 0} class="cf-del">−{file.deleted}</span>
          </span>
          <span :if={file.added == 0 and file.deleted == 0 and file.edits > 0} class="cf-edits" data-file-edits>
            {file.edits} edits
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr(:diff, :any, required: true)

  @doc """
  Settled-run change set rendered from `Harness.RunDiff.for_run/2`.

  Accepts that function's result verbatim — `{:ok, diff}` renders a summary bar
  (file count, aggregate +/- proportion) plus a collapsible per-file list, each
  file expanding to its classified hunk lines. `{:error, :branch_absent}` and
  other errors render graceful muted notes; `nil` renders nothing. Pure —
  `attr/3` + HEEx only, no `Phoenix.HTML.raw/1` on git-supplied content.
  """
  @spec run_diff_view(map()) :: Rendered.t()
  def run_diff_view(%{diff: {:ok, diff}} = assigns) do
    assigns = assign(assigns, :diff, diff)

    ~H"""
    <section class="changed-files">
      <header class="cf-head">
        <span class="cf-title">
          Changed files <span class="cf-count">{length(@diff.files)}</span>
        </span>
        <span class="cf-totals">
          <span class="cf-add">+{@diff.added}</span>
          <span class="cf-del">−{@diff.deleted}</span>
          <.stat_bar added={@diff.added} deleted={@diff.deleted} />
        </span>
      </header>

      <p :if={@diff.files == []} class="cf-empty">No file changes recorded for this run.</p>

      <details :for={file <- @diff.files} class="cf-file">
        <summary class="cf-file-head">
          <span class={"cf-status cf-status-#{file.status}"} title={to_string(file.status)}>
            {status_glyph(file.status)}
          </span>
          <.file_path path={file.path} />
          <span :if={file.binary} class="cf-binary">binary</span>
          <span class="cf-file-counts">
            <span :if={not file.binary} class="cf-add">+{file.added}</span>
            <span :if={not file.binary} class="cf-del">−{file.deleted}</span>
            <.five_square added={file.added} deleted={file.deleted} />
          </span>
        </summary>
        <div class="diff">
          <div :for={line <- render_lines(file.lines)} class={"dl dl-#{line.kind}"}>{line.text}</div>
        </div>
      </details>

      <p :if={@diff.truncated} class="cf-truncated">
        Diff truncated at 80 KB — open the <code>{@diff.branch}</code> branch for the full patch.
      </p>
      <p class="cf-branch">branch <code>{@diff.branch}</code></p>
    </section>
    """
  end

  def run_diff_view(%{diff: {:error, :branch_absent}} = assigns) do
    ~H"""
    <section class="changed-files">
      <p class="cf-note">Diff no longer available — the run branch was merged or cleaned up.</p>
    </section>
    """
  end

  def run_diff_view(%{diff: {:error, _reason}} = assigns) do
    ~H"""
    <section class="changed-files">
      <p class="cf-note">No diff available for this run.</p>
    </section>
    """
  end

  def run_diff_view(%{diff: nil} = assigns) do
    ~H"""
    <section class="changed-files"></section>
    """
  end

  attr(:path, :string, required: true)

  @doc false
  # Path typography: dimmed directory, emphasized basename.
  @spec file_path(map()) :: Rendered.t()
  def file_path(assigns) do
    assigns =
      assigns
      |> assign(:dir, path_dir(assigns.path))
      |> assign(:base, Path.basename(assigns.path))

    ~H"""
    <span class="cf-path">
      <span :if={@dir != ""} class="cf-path-dir">{@dir}/</span><span class="cf-path-base">{@base}</span>
    </span>
    """
  end

  attr(:added, :integer, required: true)
  attr(:deleted, :integer, required: true)

  @doc false
  # Continuous green/red proportion bar for the aggregate (GitHub-style summary).
  @spec stat_bar(map()) :: Rendered.t()
  def stat_bar(assigns) do
    assigns = assign(assigns, :add_pct, add_pct(assigns.added, assigns.deleted))

    ~H"""
    <span class="cf-statbar" aria-hidden="true">
      <span class="cf-statbar-add" style={"width:#{@add_pct}%"}></span>
      <span class="cf-statbar-del" style={"width:#{100 - @add_pct}%"}></span>
    </span>
    """
  end

  attr(:added, :integer, required: true)
  attr(:deleted, :integer, required: true)

  @doc false
  # Five-square per-file mini-bar (the classic ▰▰▰▱▱).
  @spec five_square(map()) :: Rendered.t()
  def five_square(assigns) do
    assigns = assign(assigns, :squares, squares(assigns.added, assigns.deleted))

    ~H"""
    <span class="cf-squares" aria-hidden="true">
      <span :for={sq <- @squares} class={"cf-sq cf-sq-#{sq}"}></span>
    </span>
    """
  end

  ## --- Run transcript view (Task 87) ---------------------------------------

  attr(:events, :list, required: true)
  attr(:agent, :atom, required: true)

  @doc """
  Renders a parsed `Harness.Dashboard.Transcript.Parser.event/0` list as
  chat-style turns on the run-detail page.

  Walks the events in arrival order and groups them into render blocks:

    * Consecutive `:assistant_text` events collapse into one
      `<.message_row role={:assistant}>` body — the same accumulator the chat
      session's text_delta loop uses, so a long streamed answer reads as one
      paragraph rather than per-token shards.
    * `:assistant_tool_use` + matching `:tool_result` pair (by
      `tool_use_id == id`) render as a single `<.tool_call>` in the
      tool_use's chronological position; an unmatched tool_use shows status
      `:pending`.
    * Consecutive `:thought` `:system` events (grok streams chain-of-thought
      token-by-token) collapse into one collapsed `<details>` "reasoning" card
      carrying the concatenated text — without this a single thought renders as
      hundreds of empty eyebrow rows.
    * Consecutive fallback `:system` events (`:other` / `:unknown`) collapse
      into one counted eyebrow row that surfaces the raw `_type` values and
      short snippets. Unknown wire edges stay visible without becoming a wall.
    * Other `:system` events render as `<.eyebrow>` metadata lines (init /
      result / thread_started / turn_started / message_end …).
    * `:plain_text` (antigravity passthrough) renders as `<pre
      class="plain-chunk">` monospace cards — no JSON tree.
    * `:unknown` renders as a muted `<details class="transcript-unknown">`
      with the raw line inside so nothing is lost when a wire-format edge
      case is hit.

  Pure component — `attr/3` declarations only; HEEx `:if` / `:for`; never
  `Phoenix.HTML.raw/1` on agent-supplied content.
  """
  @spec transcript_view(map()) :: Rendered.t()
  def transcript_view(%{events: events, agent: agent} = assigns) do
    # Group chronologically (the tool_use→tool_result pairing + turn-flush logic
    # depends on event order), then reverse the resulting BLOCKS so the newest
    # turn renders on top. Reading lands on the latest activity without scrolling
    # to the bottom — and for a live run, fresh output appears at the top where
    # the operator is already looking, not below the fold. Order *within* a turn
    # (text → its tool calls) is preserved.
    blocks = events |> group_events(agent) |> Enum.reverse()
    assigns = assign(assigns, :blocks, blocks)

    ~H"""
    <section class="transcript-view" data-agent={@agent}>
      <p :if={@blocks == []} class="transcript-empty">Waiting for output…</p>
      <.transcript_block :for={block <- @blocks} block={block} agent={@agent} />
    </section>
    """
  end

  attr(:block, :map, required: true)
  attr(:agent, :atom, required: true)

  @doc false
  @spec transcript_block(map()) :: Rendered.t()
  def transcript_block(%{block: %{kind: :assistant_message}} = assigns) do
    ~H"""
    <.message_row
      dom_id={"event-#{@block.id}"}
      role={:assistant}
      text={@block.text}
      tool_calls={@block.tool_calls}
    />
    """
  end

  def transcript_block(%{block: %{kind: :thought}} = assigns) do
    ~H"""
    <details class="transcript-thought" id={"event-#{@block.id}"}>
      <summary>reasoning</summary>
      <pre class="thought-text">{@block.text}</pre>
    </details>
    """
  end

  def transcript_block(%{block: %{kind: :system}} = assigns) do
    ~H"""
    <.eyebrow kind={@block.system_kind} data={@block.data} />
    """
  end

  def transcript_block(%{block: %{kind: :plain_text}} = assigns) do
    ~H"""
    <pre class="plain-chunk" id={"event-#{@block.id}"}>{@block.text}</pre>
    """
  end

  def transcript_block(%{block: %{kind: :unknown}} = assigns) do
    ~H"""
    <details class="transcript-unknown" id={"event-#{@block.id}"}>
      <summary>unknown chunk</summary>
      <pre>{@block.raw}</pre>
    </details>
    """
  end

  attr(:kind, :atom, required: true)
  attr(:data, :map, default: %{})

  @doc """
  Compact metadata line for a `:system` transcript event.

  The agent's lifecycle events (init / turn_started / message_end /
  rate_limit_event …) carry context that helps the reader follow the run but
  is not the assistant's reply. Renders as a single subdued line showing the
  kind label (also mirrored into `data-kind` for styling). Fallback metadata
  also surfaces its raw `_type` and a short payload snippet so unknown wire
  edges remain legible.
  """
  @spec eyebrow(map()) :: Rendered.t()
  def eyebrow(assigns) do
    assigns = assign(assigns, :summary, eyebrow_summary(assigns.data))

    ~H"""
    <p class="eyebrow" data-kind={@kind}>
      <span class="eyebrow-kind">{to_string(@kind)}</span>
      <span :if={@summary} class="eyebrow-data">{@summary}</span>
    </p>
    """
  end

  @spec eyebrow_summary(map()) :: String.t() | nil
  defp eyebrow_summary(%{count: count, types: types, snippets: snippets}) do
    [event_count_label(count), Enum.join(types, ", "), Enum.join(snippets, " | ")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp eyebrow_summary(%{"_type" => _type} = data), do: system_event_snippet(data)
  defp eyebrow_summary(_data), do: nil

  @spec event_count_label(non_neg_integer()) :: String.t()
  defp event_count_label(1), do: "1 event"
  defp event_count_label(count), do: "#{count} events"

  @spec system_event_type(atom(), map()) :: String.t()
  defp system_event_type(_kind, %{"_type" => type}) when is_binary(type), do: type
  defp system_event_type(kind, _data), do: to_string(kind)

  @spec system_event_snippet(map()) :: String.t()
  defp system_event_snippet(%{"raw" => raw}) when is_binary(raw), do: truncate_system_snippet(raw)

  defp system_event_snippet(data),
    do: data |> inspect(limit: 20, printable_limit: @system_snippet_chars) |> truncate_system_snippet()

  @spec truncate_system_snippet(String.t()) :: String.t()
  defp truncate_system_snippet(snippet) do
    if String.length(snippet) > @system_snippet_chars do
      String.slice(snippet, 0, @system_snippet_chars) <> "..."
    else
      snippet
    end
  end

  @spec unknown_raw(atom(), map()) :: String.t() | nil
  defp unknown_raw(:unknown, %{"raw" => raw}) when is_binary(raw), do: raw
  defp unknown_raw(_kind, _data), do: nil

  ## --- Config inspector (Task 127) -----------------------------------------

  attr(:sections, :list, required: true)

  @doc """
  Read-only effective-config inspector card for `SettingsLive`.

  Takes `Harness.Dashboard.ConfigInspector.resolve/0`'s section list and renders
  one titled group per concern, each a `<dl>` of key → value rows. This is an
  *inspector*, not a form: most keys are boot-time, so a row shows the resolved
  value, a provenance pill (`default` / `config.exs` / `env-set`), and — when the
  key is env-overridable — the env var that changes it (the "knob"), so the
  operator always knows *how* to change a value even though they can't here.
  Secrets arrive pre-redacted from the resolver; this component never unmasks.
  Pure — `attr/3` + HEEx only.
  """
  @spec config_inspector(map()) :: Rendered.t()
  def config_inspector(assigns) do
    ~H"""
    <section class="setting-card">
      <h2 class="setting-section-title">Configuration</h2>
      <p class="setting-desc">
        Read-only inspector of the resolved effective config — compile-time
        defaults overlaid with <code>config.exs</code>
        and runtime env-var
        overrides. Most keys are boot-time: change them in <code>config.exs</code>
        or via the env var shown on the row, then restart the node. The
        live-mutable controls (cron autonomy, agent rotation) are the toggles
        above. Secrets are redacted.
      </p>
      <ul class="config-legend">
        <li><span class="config-pill" data-prov="default">default</span> built-in default</li>
        <li><span class="config-pill" data-prov="config">config.exs</span> set in config.exs</li>
        <li><span class="config-pill" data-prov="env">env-set</span> overridden by an env var now</li>
        <li>
          <code class="config-knob">HARNESS_…</code> env var that overrides this key (on restart)
        </li>
      </ul>
      <div :for={section <- @sections} class="config-section">
        <h3 class="config-section-title">{section.title}</h3>
        <dl class="config-rows">
          <div :for={row <- section.rows} class="config-row">
            <dt class="config-key">{row.label}</dt>
            <dd class="config-val">
              <code :if={row.value != ""}>{row.value}</code>
              <code
                :if={row.env_var}
                class="config-knob"
                title="Set this env var, then restart the node."
              >
                {row.env_var}
              </code>
              <.provenance_pill provenance={row.provenance} />
            </dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  @doc """
  Editable card for the `ui_editable?` subset of the `Harness.Config` schema.

  Companion to the read-only `config_inspector/1`: where the inspector shows every
  resolved key, this renders a number input per editable key (the run timeouts +
  the dashboard port) so an operator changes them from the dashboard. Submitting a
  row fires `set_config` on the parent LiveView, which validates against the schema
  and persists through `Harness.SettingsStore`. A `restart_required?` key carries a
  pill saying the edit applies on the next boot (it is persisted, not hot-applied);
  the rest take effect on the next run. An empty input on a nullable duration means
  "unbounded" (the schema default for total/idle). Pure — `attr/3` + HEEx only.
  """
  attr(:entries, :list, required: true)

  @spec config_form(map()) :: Rendered.t()
  def config_form(assigns) do
    ~H"""
    <section class="setting-card">
      <h2 class="setting-section-title">Run &amp; dashboard config</h2>
      <p class="setting-desc">
        Live-editable config. Run timeouts take effect on the next run; an empty
        timeout means <em>unbounded</em>. Keys marked
        <span class="pill" data-state="off">restart</span>
        are persisted but apply only on the next node boot. Other keys (env vars,
        paths, secrets) stay read-only in the inspector below.
      </p>
      <ul class="project-list">
        <li :for={entry <- @entries} class="project-row">
          <form id={"config-form-#{entry.id}"} class="config-edit-form" phx-submit="set_config">
            <input type="hidden" name="key" value={entry.id} />
            <div class="project-id">
              <span class="project-name">{entry.label}</span>
              <span
                :if={entry.restart_required?}
                class="pill"
                data-state="off"
                title="Persisted now; applies on the next node boot."
              >
                restart
              </span>
            </div>
            <input
              type="number"
              name="value"
              min="0"
              value={entry.input_value}
              placeholder={entry.placeholder}
              aria-label={"#{entry.label} (#{entry.unit})"}
            />
            <span class="setting-hint">{entry.unit}</span>
            <button type="submit" class="btn-save">Save</button>
          </form>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  The per-project **Landing** card — the operator control for autonomous merge.

  Unlike the read-only config inspector, this is a *form*: each project carries a
  landing policy (`manual` / `auto-land`) and, when auto, a `target_branch`.
  Submitting fires `set_landing` on the parent LiveView, which validates (auto
  requires a branch) and persists the override via `Harness.Landing.Settings`.
  A green run only merges when the project is `auto-land` with a target branch.
  """
  attr(:projects, :list, required: true)

  @spec landing_card(map()) :: Rendered.t()
  def landing_card(assigns) do
    ~H"""
    <section class="setting-card">
      <h2 class="setting-section-title">Landing</h2>
      <p class="setting-desc">
        Per-project autonomous merge. <strong>auto-land</strong>
        merges a run into its target branch the moment it verifies green <em>and</em>
        clears the semantic gate; <strong>manual</strong>
        verifies then stops, leaving the diff in the worktree for you to land.
        Auto-land requires a target branch — without one it cannot be armed.
        The choice persists across restarts.
      </p>
      <ul class="project-list">
        <li :for={project <- @projects} class="project-row" data-effective={to_string(project.auto?)}>
          <form id={"landing-form-#{project.name}"} class="landing-form" phx-submit="set_landing">
            <input type="hidden" name="name" value={project.name} />
            <div class="project-id">
              <span class="project-name">{project.label}</span>
              <span class="pill" data-state={if project.auto?, do: "on", else: "off"}>
                {if project.auto?, do: "auto-land", else: "manual"}
              </span>
            </div>
            <select name="landing_policy" aria-label={"Landing policy for #{project.label}"}>
              <option value="manual" selected={not project.auto?}>manual</option>
              <option value="auto" selected={project.auto?}>auto-land</option>
            </select>
            <input
              type="text"
              name="target_branch"
              value={project.target_branch}
              placeholder="target branch"
              aria-label={"Target branch for #{project.label}"}
            />
            <button type="submit" class="btn-save">Save</button>
          </form>
        </li>
        <li :if={@projects == []} class="project-empty">No projects registered.</li>
      </ul>
    </section>
    """
  end

  @doc """
  Per-project registration/editing plus the quick concurrency-cap editor.
  """
  attr(:projects, :list, required: true)

  @spec project_settings_card(map()) :: Rendered.t()
  def project_settings_card(assigns) do
    ~H"""
    <section class="setting-card">
      <h2 class="setting-section-title">Projects</h2>
      <p class="setting-desc">
        Register, edit, or remove projects without changing boot config. Existing
        names update in place; new names create projects.
      </p>

      <ul class="project-list">
        <li :for={project <- @projects} class="project-row">
          <form
            id={"concurrency-form-#{project.name}"}
            class="landing-form"
            phx-submit="set_concurrency"
          >
            <input type="hidden" name="name" value={project.name} />
            <div class="project-id">
              <span class="project-name">{project.label}</span>
              <span class="pill" data-state="on">cap {project.concurrency_label}</span>
            </div>
            <input
              type="number"
              name="concurrency_cap"
              min="1"
              value={project.concurrency_cap}
              placeholder="default"
              aria-label={"Concurrency cap for #{project.label}"}
            />
            <button type="submit" class="btn-save">Save</button>
          </form>
        </li>
        <li :if={@projects == []} class="project-empty">No projects registered.</li>
      </ul>

      <ul class="project-list">
        <li :for={project <- @projects} class="project-row">
          <form id={"project-form-#{project.name}"} class="landing-form" phx-submit="save_project">
            <input
              type="text"
              name="name"
              value={project.name}
              readonly
              aria-label={"Project name #{project.label}"}
            />
            <select name="source_type" aria-label={"Source type for #{project.label}"}>
              <option value="local" selected={project.source_type == "local"}>local</option>
              <option value="github" selected={project.source_type == "github"}>github</option>
            </select>
            <input
              type="text"
              name="source_location"
              value={project.source_location}
              placeholder="source path or GitHub URL"
              aria-label={"Source location for #{project.label}"}
            />
            <input
              type="text"
              name="roadmap_path"
              value={project.roadmap_path}
              placeholder="roadmap path"
              aria-label={"Roadmap path for #{project.label}"}
            />
            <input
              type="text"
              name="check_command"
              value={project.check_command}
              placeholder="check command"
              aria-label={"Check command for #{project.label}"}
            />
            <input
              type="text"
              name="target_branch"
              value={project.target_branch}
              placeholder="target branch"
              aria-label={"Target branch for #{project.label}"}
            />
            <input
              type="number"
              name="concurrency_cap"
              min="1"
              value={project.concurrency_cap}
              placeholder="cap"
              aria-label={"Project form concurrency cap for #{project.label}"}
            />
            <textarea
              name="warm_paths"
              placeholder="warm paths"
              aria-label={"Warm paths for #{project.label}"}
            >{project.warm_paths}</textarea>
            <button type="submit" class="btn-save">Save</button>
            <button
              id={"unregister-project-#{project.name}"}
              type="button"
              class="btn-save"
              phx-click="unregister_project"
              phx-value-name={project.name}
              data-confirm={"Remove project #{project.label}?"}
            >
              Remove
            </button>
          </form>
        </li>
        <li class="project-row">
          <form id="project-form-new" class="landing-form" phx-submit="save_project">
            <input type="text" name="name" placeholder="name" aria-label="Project name" />
            <select name="source_type" aria-label="Source type">
              <option value="local">local</option>
              <option value="github">github</option>
            </select>
            <input
              type="text"
              name="source_location"
              placeholder="source path or GitHub URL"
              aria-label="Source location"
            />
            <input
              type="text"
              name="roadmap_path"
              placeholder="roadmap path"
              aria-label="Roadmap path"
            />
            <input
              type="text"
              name="check_command"
              placeholder="check command"
              aria-label="Check command"
            />
            <input
              type="text"
              name="target_branch"
              placeholder="target branch"
              aria-label="Target branch"
            />
            <input
              type="number"
              name="concurrency_cap"
              min="1"
              placeholder="cap"
              aria-label="Concurrency cap"
            />
            <textarea name="warm_paths" placeholder="warm paths" aria-label="Warm paths"></textarea>
            <button type="submit" class="btn-save">Save</button>
          </form>
        </li>
      </ul>
    </section>
    """
  end

  attr(:provenance, :atom, values: [:default, :config, :env], required: true)

  @doc false
  @spec provenance_pill(map()) :: Rendered.t()
  defp provenance_pill(assigns) do
    ~H"""
    <span class="config-pill" data-prov={@provenance}>{provenance_text(@provenance)}</span>
    """
  end

  ## --- Private helpers ------------------------------------------------------

  @spec provenance_text(atom()) :: String.t()
  defp provenance_text(:env), do: "env-set"
  defp provenance_text(:config), do: "config.exs"
  defp provenance_text(:default), do: "default"

  @spec operator_notices(term(), boolean()) :: [map()]
  defp operator_notices(notice, include_persistent) do
    persistent_operator_notices(include_persistent) ++ transient_operator_notice(notice)
  end

  @spec persistent_operator_notices(boolean()) :: [map()]
  defp persistent_operator_notices(false), do: []

  defp persistent_operator_notices(true) do
    if SettingsStore.configured() == false do
      [
        %{
          kind: :warning,
          persistent?: true,
          message: "Settings are ephemeral: changes will NOT survive a restart because the settings store is no-op."
        }
      ]
    else
      []
    end
  end

  @spec transient_operator_notice(term()) :: [map()]
  defp transient_operator_notice(nil), do: []

  defp transient_operator_notice({kind, message}) when kind in [:ok, :error] and is_binary(message) do
    [%{kind: kind, persistent?: false, message: message}]
  end

  defp transient_operator_notice(_other), do: []

  # Drops pure header `:meta` lines (diff --git / index / +++ / ---) from a
  # file's rendered body — the file row already carries that context. Hunk +
  # content lines stay.
  @spec render_lines([Harness.RunDiff.line()]) :: [Harness.RunDiff.line()]
  defp render_lines(lines), do: Enum.reject(lines, &(&1.kind == :meta))

  @spec status_glyph(Harness.RunDiff.status()) :: String.t()
  defp status_glyph(:added), do: "A"
  defp status_glyph(:modified), do: "M"
  defp status_glyph(:deleted), do: "D"
  defp status_glyph(:renamed), do: "R"

  @spec path_dir(String.t()) :: String.t()
  defp path_dir(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end

  # Added share of the change as an integer percent; an all-context (0/0) file
  # reads as balanced 50/50 rather than dividing by zero.
  @spec add_pct(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp add_pct(0, 0), do: 50
  defp add_pct(added, deleted), do: round(added * 100 / (added + deleted))

  # Five-square fill: proportional, but a non-zero side always claims at least
  # one square so a tiny minority never vanishes.
  @spec squares(non_neg_integer(), non_neg_integer()) :: [:add | :del | :none]
  defp squares(0, 0), do: List.duplicate(:none, 5)

  defp squares(added, deleted) do
    greens = added |> Kernel.*(5) |> div(added + deleted) |> clamp_share(added, deleted)
    List.duplicate(:add, greens) ++ List.duplicate(:del, 5 - greens)
  end

  @spec clamp_share(integer(), non_neg_integer(), non_neg_integer()) :: integer()
  defp clamp_share(greens, added, deleted) do
    greens
    |> max(if(added > 0, do: 1, else: 0))
    |> min(if(deleted > 0, do: 4, else: 5))
  end

  # Classifies a value for the `<.json_tree>` walker. Structs are deliberately
  # treated as `:other` so the walker inspects them rather than descending into
  # them as if they were plain maps. Local-only — `json_node/1` calls it
  # unqualified; nothing outside this module needs it.
  @spec value_kind(term()) :: :map | :list | :string | :number | :boolean | :atom | :nil_ | :other
  defp value_kind(value) when is_map(value) and not is_struct(value), do: :map
  defp value_kind(value) when is_list(value), do: :list
  defp value_kind(value) when is_binary(value), do: :string
  defp value_kind(value) when is_number(value), do: :number
  defp value_kind(value) when is_boolean(value), do: :boolean
  defp value_kind(nil), do: :nil_
  defp value_kind(value) when is_atom(value), do: :atom
  defp value_kind(_value), do: :other

  # Human label for a message role rendered by `<.message_row>`.
  @spec role_label(atom()) :: String.t()
  defp role_label(:user), do: "you"
  defp role_label(:assistant), do: "agent"
  defp role_label(:tool), do: "tool"
  defp role_label(:terminal), do: "terminal"
  defp role_label(other), do: to_string(other)

  @spec bucket_glyph(atom()) :: String.t()
  defp bucket_glyph(:in_flight), do: "◯"
  defp bucket_glyph(:repairing), do: "⟳"
  defp bucket_glyph(:green), do: "●"
  defp bucket_glyph(:red), do: "✗"

  # Walks the parser event list in arrival order and reduces it to the render
  # block list `transcript_view/1` walks. Single pass, single pre-pass —
  # neither `transcript_view/1` nor `transcript_block/1` look back; both
  # render strictly forward off the produced list.
  #
  # Grouping rules:
  #
  #   * Consecutive `:assistant_text` events fold into one `:assistant_message`
  #     block (the same single-message-body-per-turn pattern the chat session's
  #     text_delta loop uses).
  #   * `:assistant_tool_use` attaches a pending tool_call block onto the
  #     currently-open assistant message (or opens a new empty one if there's
  #     no text yet) and stamps the tool_call's `id`.
  #   * `:tool_result` looks up the open assistant message's pending tool_call
  #     by `tool_use_id` and fills its `result` + flips status to `:done`.
  #     A tool_result without a matching tool_use (rare, malformed wire) is
  #     dropped — we can't render it meaningfully without an argument tree.
  #   * Any `:system` / `:plain_text` / `:unknown` event flushes the open
  #     assistant message (closing the turn) and emits its own block.
  #
  # The opaque block id (counter) keeps DOM ids stable across re-renders of
  # the same event list without depending on event content.
  @spec group_events([Parser.event()], Parser.agent_kind()) :: [map()]
  defp group_events(events, _agent) do
    {blocks, open, _next_id} =
      Enum.reduce(events, {[], nil, 0}, &reduce_event/2)

    case open do
      nil -> Enum.reverse(blocks)
      msg -> Enum.reverse([finalize_open(msg) | blocks])
    end
  end

  # The reducer accumulator is `{closed_blocks_reversed, open_msg_or_nil, next_id}`.
  # Open assistant messages stay outside the closed list until a non-text /
  # non-tool event flushes them; this keeps the "consecutive text deltas
  # collapse" + "tool_use attaches to current turn" rules in one place.

  # Consecutive `:thought` system events fold into one `:thought` block — grok
  # streams chain-of-thought token-by-token (one `{:system, kind: :thought}`
  # per token), so without folding a single reasoning paragraph renders as
  # hundreds of empty eyebrow rows. Mirrors the `:assistant_text` accumulator.
  # Must precede the generic `:system` clause below.
  defp reduce_event({:system, %{kind: :thought, data: %{text: text}}}, {blocks, %{kind: :thought} = th, id}) do
    {blocks, %{th | text: th.text <> text}, id}
  end

  defp reduce_event({:system, %{kind: :thought, data: %{text: text}}}, acc) do
    {blocks, id} = flush_open(acc)
    {blocks, %{kind: :thought, id: id, text: text}, id + 1}
  end

  defp reduce_event({:system, %{kind: :other, data: data}}, acc) do
    reduce_fallback_system(:other, data, acc)
  end

  defp reduce_event({:system, %{kind: :unknown, data: data}}, acc) do
    reduce_fallback_system(:unknown, data, acc)
  end

  defp reduce_event({:assistant_text, %{text: text}}, {blocks, %{kind: :assistant_message} = msg, id}) do
    {blocks, %{msg | text: msg.text <> text}, id}
  end

  defp reduce_event({:assistant_text, %{text: text}}, acc) do
    {blocks, id} = flush_open(acc)
    {blocks, new_message(id, %{text: text}), id + 1}
  end

  defp reduce_event({:assistant_tool_use, tool_use}, {blocks, %{kind: :assistant_message} = msg, id}) do
    {blocks, %{msg | tool_calls: msg.tool_calls ++ [build_tool_call(tool_use)]}, id}
  end

  defp reduce_event({:assistant_tool_use, tool_use}, acc) do
    {blocks, id} = flush_open(acc)
    {blocks, new_message(id, %{tool_calls: [build_tool_call(tool_use)]}), id + 1}
  end

  defp reduce_event(
         {:tool_result, %{tool_use_id: tool_use_id, content: content}},
         {blocks, %{kind: :assistant_message} = msg, id}
       ) do
    {blocks, %{msg | tool_calls: fill_tool_result(msg.tool_calls, tool_use_id, content)}, id}
  end

  defp reduce_event({:tool_result, _result}, acc) do
    # No open assistant_message to attach to (open is nil or a thought block).
    # Flush any open thought; the orphan result has no render target, drop it.
    {blocks, id} = flush_open(acc)
    {blocks, nil, id}
  end

  defp reduce_event({:system, %{kind: kind, data: data}}, acc) do
    flush_and_emit(acc, fn id -> %{kind: :system, id: id, system_kind: kind, data: data} end)
  end

  defp reduce_event({:plain_text, %{text: text}}, acc) do
    flush_and_emit(acc, fn id -> %{kind: :plain_text, id: id, text: text} end)
  end

  defp reduce_event({:unknown, %{raw: raw}}, acc) do
    reduce_fallback_system(:unknown, %{"_type" => "unknown", "raw" => raw}, acc)
  end

  # Flushes the open assistant message (if any) into the closed list before
  # emitting a non-message block.
  defp flush_and_emit({blocks, nil, id}, build_block) do
    {[build_block.(id) | blocks], nil, id + 1}
  end

  defp flush_and_emit({blocks, msg, id}, build_block) do
    {[build_block.(id) | [finalize_open(msg) | blocks]], nil, id + 1}
  end

  # Closes any currently-open block (assistant_message or thought) into the
  # closed list, returning `{blocks, next_id}` for the caller to open a fresh
  # block. The open block already owns its id, so the counter is untouched.
  defp flush_open({blocks, nil, id}), do: {blocks, id}
  defp flush_open({blocks, open, id}), do: {[finalize_open(open) | blocks], id}

  @spec reduce_fallback_system(atom(), map(), {list(), map() | nil, non_neg_integer()}) ::
          {list(), map(), non_neg_integer()}
  defp reduce_fallback_system(kind, data, {blocks, %{kind: :system_group} = group, id}) do
    {blocks, append_system_group(group, kind, data), id}
  end

  defp reduce_fallback_system(kind, data, acc) do
    {blocks, id} = flush_open(acc)
    {blocks, new_system_group(id, kind, data), id + 1}
  end

  @spec new_system_group(non_neg_integer(), atom(), map()) :: map()
  defp new_system_group(id, kind, data) do
    %{
      kind: :system_group,
      id: id,
      count: 1,
      types: [system_event_type(kind, data)],
      snippets: [system_event_snippet(data)],
      unknown_raw: unknown_raw(kind, data)
    }
  end

  @spec append_system_group(map(), atom(), map()) :: map()
  defp append_system_group(group, kind, data) do
    %{
      group
      | count: group.count + 1,
        types: [system_event_type(kind, data) | group.types],
        snippets: [system_event_snippet(data) | group.snippets],
        unknown_raw: group.unknown_raw || unknown_raw(kind, data)
    }
  end

  @spec finalize_open(map()) :: map()
  defp finalize_open(%{kind: :system_group, count: 1, id: id, unknown_raw: raw}) when is_binary(raw) do
    %{kind: :unknown, id: id, raw: raw}
  end

  defp finalize_open(%{kind: :system_group} = group) do
    %{
      kind: :system,
      id: group.id,
      system_kind: :other,
      data: %{
        count: group.count,
        types: group.types |> Enum.reverse() |> Enum.uniq(),
        snippets: group.snippets |> Enum.reverse() |> Enum.uniq()
      }
    }
  end

  defp finalize_open(open), do: open

  defp new_message(id, fields) do
    Map.merge(%{kind: :assistant_message, id: id, text: "", tool_calls: []}, fields)
  end

  defp build_tool_call(%{id: id, name: name, input: input}) do
    %{id: id, name: name, args: input, result: nil, status: :pending}
  end

  defp fill_tool_result(tool_calls, tool_use_id, content) do
    Enum.map(tool_calls, fn
      %{id: ^tool_use_id} = tc -> %{tc | result: content, status: :done}
      tc -> tc
    end)
  end

  @spec accumulate_file_stat(Parser.event(), {list(String.t()), map()}) ::
          {list(String.t()), map()}
  defp accumulate_file_stat({:assistant_tool_use, %{name: name, input: input}}, {order, stats}) do
    case file_path_from_input(input) do
      nil ->
        {order, stats}

      path ->
        {added, deleted} = line_delta(name, input)
        order = if path in order, do: order, else: order ++ [path]

        stats =
          Map.update(stats, path, blank_file_stat(added, deleted), fn entry ->
            %{
              entry
              | added: entry.added + added,
                deleted: entry.deleted + deleted,
                edits: entry.edits + 1
            }
          end)

        {order, stats}
    end
  end

  defp accumulate_file_stat(_event, acc), do: acc

  @spec blank_file_stat(non_neg_integer(), non_neg_integer()) :: %{
          added: non_neg_integer(),
          deleted: non_neg_integer(),
          edits: non_neg_integer()
        }
  defp blank_file_stat(added, deleted), do: %{added: added, deleted: deleted, edits: 1}

  @spec activity_phrase(%{name: String.t(), input: term()}) :: String.t()
  defp activity_phrase(%{name: name, input: input}) do
    path = file_path_from_input(input)
    command = command_from_input(input)

    cond do
      path && edit_tool_name?(name) -> "editing #{path}"
      path && write_tool_name?(name) -> "writing #{path}"
      path -> "#{name} #{path}"
      command -> "running #{truncate_command(command)}"
      true -> "calling #{name}"
    end
  end

  @spec edit_tool_name?(String.t()) :: boolean()
  defp edit_tool_name?(name) do
    down = String.downcase(name)
    String.contains?(down, "edit") or down in ["search_replace", "strreplace", "replace"]
  end

  @spec write_tool_name?(String.t()) :: boolean()
  defp write_tool_name?(name) do
    down = String.downcase(name)
    down in ["write", "create", "writefile"]
  end

  @spec file_path_from_input(term()) :: String.t() | nil
  defp file_path_from_input(input) when is_map(input) do
    input["file_path"] || input["path"] || input[:file_path] || input[:path]
  end

  defp file_path_from_input(_other), do: nil

  @spec command_from_input(term()) :: String.t() | nil
  defp command_from_input(input) when is_map(input) do
    input["command"] || input[:command]
  end

  defp command_from_input(_other), do: nil

  @spec truncate_command(String.t()) :: String.t()
  defp truncate_command(command) do
    command
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 80)
  end

  @spec line_delta(String.t(), map()) :: {non_neg_integer(), non_neg_integer()}
  defp line_delta(name, input) do
    down = String.downcase(name)

    cond do
      String.contains?(down, "multi") ->
        edits = input_field(input, :edits) || []

        Enum.reduce(edits, {0, 0}, fn edit, {added, deleted} ->
          edit = normalize_map(edit)

          {added + line_count(input_field(edit, :new_string)),
           deleted + line_count(input_field(edit, :old_string))}
        end)

      input_field(input, :old_string) != nil ->
        {line_count(input_field(input, :new_string)), line_count(input_field(input, :old_string))}

      input_field(input, :new_string) != nil ->
        {line_count(input_field(input, :new_string)), 0}

      input_field(input, :contents) != nil ->
        {line_count(input_field(input, :contents)), 0}

      true ->
        {0, 0}
    end
  end

  @spec input_field(map(), atom()) :: term()
  defp input_field(input, key) when is_map(input) do
    input[key] || input[Atom.to_string(key)]
  end

  defp input_field(_input, _key), do: nil

  @spec normalize_map(term()) :: map()
  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_map(_other), do: %{}

  @spec line_count(term()) :: non_neg_integer()
  defp line_count(nil), do: 0
  defp line_count(""), do: 0

  defp line_count(text) when is_binary(text) do
    text |> String.split("\n", trim: false) |> length()
  end

  defp line_count(_other), do: 0
end
