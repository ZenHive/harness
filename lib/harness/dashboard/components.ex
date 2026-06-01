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
  alias Phoenix.LiveView.Rendered

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

  ## --- Changed files / run diff --------------------------------------------

  attr(:paths, :list, required: true)

  @doc """
  In-progress edited-file list for a *live* run.

  A live run has no commit yet, so the change signal comes from the agent's
  own file-editing tool calls (extracted upstream from the parsed transcript
  events). Renders each path as a chip with a pulsing live dot; an empty list
  shows a waiting note. Pure — `attr/3` + HEEx only.
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
      <p :if={@paths == []} class="cf-empty">No file edits observed yet.</p>
      <ul :if={@paths != []} class="cf-chips">
        <li :for={path <- @paths} class="cf-chip">
          <.file_path path={path} />
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
    assigns = assign(assigns, :blocks, group_events(events, agent))

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
  kind label (also mirrored into `data-kind` for styling). The `data` payload
  is accepted but not surfaced in the markup — kept on the assign so a future
  expand-on-click can reveal it without a signature change.
  """
  @spec eyebrow(map()) :: Rendered.t()
  def eyebrow(assigns) do
    ~H"""
    <p class="eyebrow" data-kind={@kind}>
      <span class="eyebrow-kind">{to_string(@kind)}</span>
    </p>
    """
  end

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
      msg -> Enum.reverse([msg | blocks])
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
    flush_and_emit(acc, fn id -> %{kind: :unknown, id: id, raw: raw} end)
  end

  # Flushes the open assistant message (if any) into the closed list before
  # emitting a non-message block.
  defp flush_and_emit({blocks, nil, id}, build_block) do
    {[build_block.(id) | blocks], nil, id + 1}
  end

  defp flush_and_emit({blocks, msg, id}, build_block) do
    {[build_block.(id) | [msg | blocks]], nil, id + 1}
  end

  # Closes any currently-open block (assistant_message or thought) into the
  # closed list, returning `{blocks, next_id}` for the caller to open a fresh
  # block. The open block already owns its id, so the counter is untouched.
  defp flush_open({blocks, nil, id}), do: {blocks, id}
  defp flush_open({blocks, open, id}), do: {[open | blocks], id}

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
end
