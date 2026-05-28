defmodule Harness.Dashboard.Tokens do
  @moduledoc """
  Design-token surface for the harness dashboard.

  Typography commitment: **Geist Sans** for display + body and **Geist Mono**
  for code / run-ids / tool-call JSON. Both load via jsdelivr from the
  upstream `geist` npm package (Vercel's OFL-licensed family) as variable
  woff2 with `font-display: swap`. The mpp.dev pixel-square variant is
  brand-custom and intentionally not adopted; `navbar/1`'s wordmark uses
  Geist Sans with tracking + lowercase styling instead. See
  `Harness.Dashboard.Components` `@moduledoc` § "Font sourcing" for the
  decision history.

  Dark-mode-first colour: a dominant neutral plane (`--bg`, `--surface`,
  `--surface-2`, `--text`, `--text-subtle`, `--rule`) plus one sharp signal
  `--accent` reserved for terminal-state cues — verdict pass/fail, error,
  stream-finished. The accent never appears on neutral controls.

  Motion tokens (`--motion-fast`, `--motion-base`, `--motion-slow`) plus
  easing variables; a single bottom-of-stylesheet
  `@media (prefers-reduced-motion: reduce)` block silences decorative
  motion. Gating is at the CSS layer so the LiveView never branches on the
  motion preference.

  All dashboard surfaces (`Harness.Dashboard.Live`, `Harness.Dashboard.ChatLive`,
  and the shared chrome in `Harness.Dashboard.Components`) inherit this
  vocabulary by virtue of `<.stylesheet />` mounting once in `root.html.heex`.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.Rendered

  @doc """
  Emits the dashboard's global font imports and design-token stylesheet.

  Call once at the top of the root layout — `<.stylesheet />` — and nowhere
  else.
  """
  @spec stylesheet(map()) :: Rendered.t()
  def stylesheet(assigns) do
    ~H"""
    <link rel="preconnect" href="https://cdn.jsdelivr.net" crossorigin="anonymous" />
    <style>
      @font-face {
        font-family: "Geist";
        src: url("https://cdn.jsdelivr.net/npm/geist@latest/dist/fonts/geist-sans/Geist-Variable.woff2") format("woff2-variations");
        font-weight: 100 900;
        font-style: normal;
        font-display: swap;
      }
      @font-face {
        font-family: "Geist Mono";
        src: url("https://cdn.jsdelivr.net/npm/geist@latest/dist/fonts/geist-mono/GeistMono-Variable.woff2") format("woff2-variations");
        font-weight: 100 900;
        font-style: normal;
        font-display: swap;
      }

      :root {
        color-scheme: dark;

        /* Typography */
        --font-display: "Geist", ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
        --font-mono: "Geist Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
        --font-body: var(--font-display);

        /* Type scale — tightened for higher info density (Task 85) */
        --text-xs: 0.7rem;
        --text-sm: 0.8rem;
        --text-base: 0.9rem;
        --text-md: 1.0rem;
        --text-lg: 1.15rem;
        --text-xl: 1.4rem;
        --text-2xl: 1.8rem;

        /* Spacing scale */
        --space-1: 0.25rem;
        --space-2: 0.5rem;
        --space-3: 0.75rem;
        --space-4: 1rem;
        --space-5: 1.5rem;
        --space-6: 2.25rem;
        --space-7: 3.5rem;

        /* Layout */
        --page-max-width: 1240px;
        --navbar-height: 3.25rem;
        --footer-height: 2.5rem;

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
        padding: 0;
        font-family: var(--font-body);
        font-size: var(--text-base);
        line-height: 1.55;
        font-feature-settings: "ss01", "ss03", "cv11";
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
        letter-spacing: -0.01em;
      }

      h1 { font-size: var(--text-2xl); font-weight: 600; letter-spacing: -0.02em; }
      h2 { font-size: var(--text-xl); }
      h3 { font-size: var(--text-lg); color: var(--text-subtle); }

      a { color: inherit; text-decoration: underline; text-decoration-color: var(--rule); text-underline-offset: 3px; }
      a:hover { text-decoration-color: var(--accent); }

      code, pre, kbd { font-family: var(--font-mono); font-size: 0.92em; }

      hr { border: 0; border-top: 1px solid var(--rule); margin-block: var(--space-4); }

      /* === Page shell — persistent chrome (Task 85) === */

      .page-shell {
        display: grid;
        grid-template-rows: var(--navbar-height) 1fr auto;
        min-height: 100vh;
      }

      .page-main {
        max-width: var(--page-max-width);
        width: 100%;
        margin-inline: auto;
        padding: var(--space-5) var(--space-5) var(--space-6);
        box-sizing: border-box;
      }

      /* Navbar */
      .navbar {
        position: sticky;
        top: 0;
        z-index: 50;
        display: flex;
        align-items: center;
        justify-content: space-between;
        height: var(--navbar-height);
        padding-inline: var(--space-5);
        background: rgba(11, 12, 16, 0.85);
        backdrop-filter: blur(12px) saturate(140%);
        -webkit-backdrop-filter: blur(12px) saturate(140%);
        border-bottom: 1px solid var(--rule);
      }
      .navbar-brand {
        text-decoration: none;
        display: inline-flex;
        align-items: baseline;
        gap: var(--space-2);
      }
      .navbar-brand:hover { text-decoration: none; }
      .brand-mark {
        font-family: var(--font-display);
        font-weight: 600;
        font-size: var(--text-md);
        letter-spacing: 0.02em;
        color: var(--text);
      }
      .navbar-links {
        display: flex;
        align-items: center;
        gap: var(--space-1);
      }
      .navbar-links a {
        text-decoration: none;
        padding: var(--space-1) var(--space-3);
        border-radius: 0.3rem;
        font-family: var(--font-display);
        font-size: var(--text-sm);
        color: var(--text-subtle);
        transition: color var(--motion-fast) var(--ease-out), background-color var(--motion-fast) var(--ease-out);
      }
      .navbar-links a:hover {
        color: var(--text);
        background: var(--surface);
      }
      .navbar-links a[data-active="true"] {
        color: var(--text);
        background: var(--surface-2);
        box-shadow: inset 0 -1px 0 var(--accent);
      }

      /* Footer */
      .page-footer {
        max-width: var(--page-max-width);
        width: 100%;
        margin-inline: auto;
        padding: var(--space-3) var(--space-5);
        box-sizing: border-box;
        display: flex;
        align-items: baseline;
        gap: var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-xs);
        color: var(--text-muted);
        border-top: 1px solid var(--rule);
        min-height: var(--footer-height);
      }
      .footer-mark { font-weight: 600; color: var(--text-subtle); }
      .footer-tag { letter-spacing: 0.02em; }

      /* === Operator dashboard (Harness.Dashboard.Live) — rehome === */

      table { border-collapse: collapse; width: 100%; margin-block: var(--space-3); }
      th, td { text-align: left; padding: var(--space-2) var(--space-3); border-bottom: 1px solid var(--rule); }
      th { font-weight: 600; color: var(--text-subtle); font-family: var(--font-display); font-size: var(--text-sm); }

      /* Bucket badges — glyph + label, classified per bucket */
      .bucket {
        display: inline-flex;
        align-items: center;
        gap: 0.35rem;
        padding: 0.15rem 0.5rem;
        border-radius: 0.3rem;
        font-size: var(--text-xs);
        font-weight: 600;
        font-family: var(--font-mono);
        letter-spacing: 0.02em;
      }
      .bucket-glyph { font-size: 0.9em; line-height: 1; }
      .bucket-label { text-transform: lowercase; }
      .bucket-in_flight  { background: rgba(74, 127, 168, 0.18);  color: var(--verdict-info); }
      .bucket-repairing  { background: rgba(184, 123, 53, 0.18);  color: var(--verdict-warn); }
      .bucket-green      { background: rgba(79, 155, 106, 0.18);  color: var(--verdict-pass); }
      .bucket-red        { background: rgba(194, 90, 74, 0.18);   color: var(--verdict-fail); }

      .topbar {
        display: flex;
        flex-wrap: wrap;
        gap: var(--space-3) var(--space-4);
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
        border-radius: 0.25rem;
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
        min-height: calc(100vh - var(--navbar-height) - var(--footer-height) - var(--space-7));
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
        margin-left: var(--space-3);
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
        grid-template-columns: 7rem 1fr;
        gap: var(--space-4);
        padding-block: var(--space-3);
        border-top: 1px solid var(--rule);
        animation: msg-arrive var(--motion-base) var(--ease-out);
      }
      .msg:first-child { border-top: 0; }

      .msg-role {
        font-family: var(--font-display);
        font-size: var(--text-xs);
        color: var(--text-subtle);
        letter-spacing: 0.06em;
        text-transform: uppercase;
        font-weight: 600;
      }

      .msg-body {
        font-size: var(--text-md);
        white-space: pre-wrap;
        word-break: break-word;
      }

      .msg-user      { background: linear-gradient(180deg, rgba(255,255,255,0.02), transparent); }
      .msg-user .msg-role { color: var(--text); font-weight: 700; }

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
