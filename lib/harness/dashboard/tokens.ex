defmodule Harness.Dashboard.Tokens do
  @moduledoc """
  Design-token surface for the harness dashboard (Task 78).

  Typography commitment: **Fraunces** for display (headings, role labels,
  summary text — a characterful serif with optical-size variants) paired with
  **JetBrains Mono** for monospace (run-ids, tool-call JSON, code spans).
  Both ship from Google Fonts with `font-display: swap`; the system-ui /
  Inter / Roboto / Arial / Space Grotesk family is intentionally excluded
  per Task 78's typography constraints.

  Dark-mode-first colour: a dominant neutral plane (`--bg`, `--surface`,
  `--surface-2`, `--text`, `--text-subtle`, `--rule`) plus one sharp signal
  `--accent` reserved for terminal-state cues — verdict pass/fail, error,
  stream-finished. The accent never appears on neutral controls.

  Motion tokens (`--motion-fast`, `--motion-base`, `--motion-slow`) plus
  easing variables; a single bottom-of-stylesheet
  `@media (prefers-reduced-motion: reduce)` block silences decorative
  motion. Gating is at the CSS layer so the LiveView never branches on the
  motion preference.

  Tasks 80 and 81 inherit this vocabulary unmodified by calling
  `<Harness.Dashboard.Tokens.stylesheet />` in their root layout. The
  legacy bucket / field / transcript classes used by the operator dashboard
  (`Harness.Dashboard.Live`) rehome inside this stylesheet so the existing
  views keep working without local edits.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.Rendered

  @doc """
  Emits the dashboard's global font imports and design-token stylesheet.

  Call once at the top of the root layout — `<.stylesheet />` — and nowhere
  else. Tasks 80 and 81 must call this exact component rather than declaring
  their own tokens.
  """
  @spec stylesheet(map()) :: Rendered.t()
  def stylesheet(assigns) do
    ~H"""
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous" />
    <link
      rel="stylesheet"
      href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,500;9..144,600;9..144,700&family=JetBrains+Mono:wght@400;500;700&display=swap"
    />
    <style>
      :root {
        color-scheme: dark;

        /* Typography */
        --font-display: "Fraunces", ui-serif, Georgia, serif;
        --font-mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
        --font-body: var(--font-display);

        /* Type scale */
        --text-xs: 0.75rem;
        --text-sm: 0.85rem;
        --text-base: 0.95rem;
        --text-md: 1.05rem;
        --text-lg: 1.25rem;
        --text-xl: 1.6rem;
        --text-2xl: 2.1rem;

        /* Spacing scale */
        --space-1: 0.25rem;
        --space-2: 0.5rem;
        --space-3: 0.75rem;
        --space-4: 1rem;
        --space-5: 1.5rem;
        --space-6: 2.25rem;
        --space-7: 3.5rem;

        /* Neutral plane (dark-mode-first) */
        --bg: #0b0c10;
        --surface: #15171d;
        --surface-2: #1c1f27;
        --rule: #2a2e38;
        --text: #e8e5dd;
        --text-subtle: #8a8e98;
        --text-muted: #5c606a;

        /* Single signal accent — terminal-state cues only */
        --accent: #e6a14b;
        --accent-soft: rgba(230, 161, 75, 0.16);

        /* Verdict tints — same restraint, used on dashboard run badges only */
        --verdict-pass: #4f9b6a;
        --verdict-fail: #c25a4a;
        --verdict-info: #4a7fa8;
        --verdict-warn: #b87b35;

        /* Motion */
        --motion-fast: 120ms;
        --motion-base: 200ms;
        --motion-slow: 380ms;
        --ease-out: cubic-bezier(0.22, 0.61, 0.36, 1);
        --ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);
      }

      html, body {
        background: var(--bg);
        color: var(--text);
      }

      body {
        margin: 0;
        padding: var(--space-5);
        max-width: 1200px;
        margin-inline: auto;
        font-family: var(--font-body);
        font-size: var(--text-base);
        line-height: 1.55;
        font-feature-settings: "ss01", "ss02";
        position: relative;
      }

      body::before {
        content: "";
        position: fixed;
        inset: 0;
        z-index: -1;
        pointer-events: none;
        background:
          radial-gradient(ellipse 80rem 40rem at 50% -20%, rgba(230, 161, 75, 0.04), transparent 60%),
          linear-gradient(180deg, #0d0f14 0%, var(--bg) 60%);
      }

      h1, h2, h3, h4 {
        margin-block: var(--space-3);
        font-family: var(--font-display);
        font-weight: 500;
        letter-spacing: -0.005em;
      }

      h1 { font-size: var(--text-2xl); font-weight: 600; }
      h2 { font-size: var(--text-xl); }
      h3 { font-size: var(--text-lg); color: var(--text-subtle); }

      a { color: inherit; text-decoration: underline; text-decoration-color: var(--rule); text-underline-offset: 3px; }
      a:hover { text-decoration-color: var(--accent); }

      code, pre, kbd { font-family: var(--font-mono); font-size: 0.92em; }

      hr { border: 0; border-top: 1px solid var(--rule); margin-block: var(--space-4); }

      /* === Operator dashboard (Harness.Dashboard.Live) — rehome === */

      table { border-collapse: collapse; width: 100%; margin-block: var(--space-3); }
      th, td { text-align: left; padding: var(--space-2) var(--space-3); border-bottom: 1px solid var(--rule); }
      th { font-weight: 600; color: var(--text-subtle); font-family: var(--font-display); }

      .bucket {
        display: inline-block;
        padding: 0.15rem 0.55rem;
        border-radius: 0.25rem;
        font-size: var(--text-xs);
        font-weight: 600;
        font-family: var(--font-mono);
      }
      .bucket-in_flight  { background: rgba(74, 127, 168, 0.18);  color: var(--verdict-info); }
      .bucket-repairing  { background: rgba(184, 123, 53, 0.18);  color: var(--verdict-warn); }
      .bucket-green      { background: rgba(79, 155, 106, 0.18);  color: var(--verdict-pass); }
      .bucket-red        { background: rgba(194, 90, 74, 0.18);   color: var(--verdict-fail); }

      .topbar {
        display: flex;
        gap: var(--space-4);
        align-items: baseline;
        margin-bottom: var(--space-4);
        padding-bottom: var(--space-3);
        border-bottom: 1px solid var(--rule);
      }
      .topbar a {
        text-decoration: none;
        padding: var(--space-1) var(--space-3);
        border: 1px solid var(--rule);
        border-radius: 0.25rem;
        font-size: var(--text-sm);
      }
      .topbar select {
        background: var(--surface);
        color: var(--text);
        border: 1px solid var(--rule);
        padding: var(--space-1) var(--space-2);
        font-family: var(--font-mono);
        font-size: var(--text-sm);
      }
      .count { font-size: var(--text-sm); color: var(--text-subtle); }

      pre.transcript {
        background: var(--surface);
        padding: var(--space-3);
        border-radius: 0.5rem;
        max-height: 32rem;
        overflow: auto;
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        border: 1px solid var(--rule);
      }

      .field {
        display: grid;
        grid-template-columns: 12rem 1fr;
        gap: 0.3rem 1rem;
        margin-block: var(--space-2);
        font-size: var(--text-sm);
      }
      .field dt { color: var(--text-subtle); }
      .field dd { margin: 0; font-family: var(--font-mono); }

      /* === Chat surface (Harness.Dashboard.ChatLive) === */

      .chat-shell {
        display: flex;
        flex-direction: column;
        gap: var(--space-4);
        min-height: calc(100vh - 4rem);
      }

      .chat-header {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
        gap: var(--space-4);
        padding-bottom: var(--space-3);
        border-bottom: 1px solid var(--rule);
      }
      .chat-header h1 { margin: 0; }
      .chat-header .session-id {
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        color: var(--text-muted);
      }
      .chat-header button {
        background: transparent;
        color: var(--text);
        border: 1px solid var(--rule);
        border-radius: 0.25rem;
        padding: var(--space-1) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        cursor: pointer;
      }
      .chat-header button:hover { border-color: var(--accent); }

      .messages {
        display: flex;
        flex-direction: column;
        gap: var(--space-5);
        flex: 1;
      }

      .msg {
        display: grid;
        grid-template-columns: 8rem 1fr;
        gap: var(--space-4);
        padding-block: var(--space-3);
        border-top: 1px solid var(--rule);
        animation: msg-arrive var(--motion-base) var(--ease-out);
      }
      .msg:first-child { border-top: 0; }

      .msg-role {
        font-family: var(--font-display);
        font-size: var(--text-sm);
        color: var(--text-subtle);
        letter-spacing: 0.04em;
        text-transform: uppercase;
        font-feature-settings: "smcp";
      }

      .msg-body {
        font-size: var(--text-md);
        white-space: pre-wrap;
        word-break: break-word;
      }

      .msg-user      { background: linear-gradient(180deg, rgba(255,255,255,0.02), transparent); }
      .msg-user .msg-role { color: var(--text); font-weight: 600; }

      .msg-assistant .msg-body { line-height: 1.7; }

      .msg-terminal { border-left: 2px solid var(--accent); padding-left: var(--space-3); }
      .msg-terminal .msg-role { color: var(--accent); font-weight: 700; }
      .msg-terminal .msg-body { font-family: var(--font-mono); font-size: var(--text-sm); color: var(--text); }

      /* Streaming-token cursor: present only while data-streaming="true" */
      .msg-body[data-streaming="true"]::after {
        content: "▍";
        display: inline-block;
        margin-left: 0.1em;
        color: var(--accent);
        animation: cursor-pulse 1s var(--ease-in-out) infinite;
      }

      .tool-call {
        margin-top: var(--space-3);
        background: var(--surface);
        border: 1px solid var(--rule);
        border-radius: 0.35rem;
        overflow: hidden;
        transition: border-color var(--motion-base) var(--ease-out);
      }
      .tool-call[open] { border-color: rgba(230, 161, 75, 0.35); }

      .tool-call > summary {
        list-style: none;
        cursor: pointer;
        padding: var(--space-2) var(--space-3);
        display: flex;
        align-items: center;
        gap: var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
      }
      .tool-call > summary::-webkit-details-marker { display: none; }
      .tool-call > summary::before {
        content: "▸";
        font-family: var(--font-mono);
        color: var(--text-muted);
        transition: transform var(--motion-fast) var(--ease-out);
        display: inline-block;
        width: 0.7em;
      }
      .tool-call[open] > summary::before { transform: rotate(90deg); }

      .tool-call .tool-name { font-family: var(--font-mono); color: var(--text); }
      .tool-call .tool-status {
        margin-left: auto;
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        text-transform: lowercase;
      }
      .tool-call .tool-status[data-status="pending"]::before { content: "● "; color: var(--verdict-info); }
      .tool-call .tool-status[data-status="done"]::before    { content: "● "; color: var(--verdict-pass); }

      .tool-call .tool-body { padding: var(--space-3); border-top: 1px solid var(--rule); }
      .tool-call .tool-section { margin-block: var(--space-2); }
      .tool-call .tool-section-label {
        font-family: var(--font-display);
        font-size: var(--text-xs);
        color: var(--text-subtle);
        letter-spacing: 0.04em;
        text-transform: uppercase;
        margin-bottom: var(--space-1);
      }

      /* json_tree component */
      .jtree {
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        line-height: 1.6;
      }
      .jtree dl { margin: 0; }
      .jtree dt { color: var(--text-subtle); display: inline; margin-right: 0.4em; }
      .jtree dt::after { content: ":"; color: var(--text-muted); }
      .jtree dd { display: block; margin: 0 0 var(--space-1) var(--space-3); }
      .jtree ol { margin: 0 0 0 var(--space-3); padding: 0; list-style: none; counter-reset: idx; }
      .jtree ol > li { counter-increment: idx; }
      .jtree ol > li::before {
        content: counter(idx) ".";
        color: var(--text-muted);
        margin-right: 0.4em;
      }
      .jtree .leaf-string  { color: var(--text); }
      .jtree .leaf-number  { color: var(--verdict-info); }
      .jtree .leaf-bool    { color: var(--verdict-warn); }
      .jtree .leaf-atom    { color: var(--verdict-pass); }
      .jtree .leaf-nil     { color: var(--text-muted); font-style: italic; }
      .jtree .leaf-other   { color: var(--text-muted); }
      .jtree .empty        { color: var(--text-muted); font-style: italic; }

      /* Composer */
      .composer {
        display: grid;
        grid-template-columns: 1fr auto;
        gap: var(--space-3);
        align-items: end;
        padding: var(--space-3);
        background: var(--surface);
        border: 1px solid var(--rule);
        border-radius: 0.5rem;
        position: sticky;
        bottom: var(--space-3);
      }
      .composer textarea {
        width: 100%;
        min-height: 3rem;
        max-height: 16rem;
        resize: vertical;
        background: var(--bg);
        color: var(--text);
        border: 1px solid var(--rule);
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-md);
        line-height: 1.5;
      }
      .composer textarea:focus { outline: 1px solid var(--accent); outline-offset: 1px; }
      .composer button {
        background: var(--accent);
        color: #14110a;
        border: 0;
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-5);
        font-family: var(--font-display);
        font-size: var(--text-md);
        font-weight: 600;
        cursor: pointer;
        transition: opacity var(--motion-fast) var(--ease-out);
      }
      .composer button:disabled { opacity: 0.45; cursor: not-allowed; }

      .empty-state {
        color: var(--text-muted);
        font-family: var(--font-display);
        font-size: var(--text-md);
        padding-block: var(--space-6);
        text-align: center;
        border: 1px dashed var(--rule);
        border-radius: 0.5rem;
      }

      /* Motion keyframes — guarded by prefers-reduced-motion at the bottom */
      @keyframes msg-arrive {
        from { opacity: 0; transform: translateY(0.4rem); }
        to   { opacity: 1; transform: none; }
      }
      @keyframes cursor-pulse {
        0%, 60% { opacity: 1; }
        61%, 100% { opacity: 0.15; }
      }

      @media (prefers-reduced-motion: reduce) {
        *, *::before, *::after {
          animation-duration: 0.01ms !important;
          animation-iteration-count: 1 !important;
          transition-duration: 0.01ms !important;
        }
      }
    </style>
    """
  end
end
