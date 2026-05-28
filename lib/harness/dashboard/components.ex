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

  ## --- Private helpers ------------------------------------------------------

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
end
