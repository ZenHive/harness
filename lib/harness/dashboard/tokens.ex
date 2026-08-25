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

  Connection witness: the stylesheet reads LiveView's own container classes
  (`phx-connected` / `phx-loading` / `phx-error` + `phx-client-error` |
  `phx-server-error`) through `:has()` on `.page-shell`, dims `.page-main`
  when the socket is not live, and pins `.page-footer` to the viewport to
  carry the statement. `:has()` is load-bearing here — the classes land on
  the LiveView root container *inside* `.page-main`, so the chrome can only
  see them by ancestor query. Every line, including "Connected", is keyed
  positively off its own `phx-*` class rather than off the absence of one —
  before JS boots (or if it never does), none of the four is revealed, so
  the footer sits empty instead of asserting a connection that isn't there.

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
        /* Border/divider tokens are non-text (WCAG 2.1 SC 1.4.11, 3:1
           minimum) — table row dividers, form-control and toggle-switch
           borders, and the degraded-connection footer boundary all use this
           value against --bg/--surface/--surface-2. Keep >=3:1 against all
           three; don't round it back down toward the old #555e72. */
        --rule-strong: #737c98;
        --text: #e8e5dd;
        --text-subtle: #8a8e98;
        --text-muted: #808694;

        /* Single signal accent — terminal-state cues only */
        --accent: #e6a14b;
        --accent-soft: rgba(230, 161, 75, 0.16);

        /* Verdict tints — same restraint, used on dashboard run badges only */
        --verdict-pass: #4f9b6a;
        --verdict-fail: #c25a4a;
        --verdict-info: #4a7fa8;
        --verdict-warn: #b87b35;

        /* Diff — line-level washes + edges (RunDiff change view) */
        --diff-add-fg: #5fb07e;
        --diff-del-fg: #cf6b5a;
        --diff-add-edge: #4f9b6a;
        --diff-del-edge: #c25a4a;
        --diff-add-bg: rgba(79, 155, 106, 0.12);
        --diff-del-bg: rgba(194, 90, 74, 0.12);

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
        grid-template-columns: minmax(0, 1fr);
        min-height: 100vh;
      }

      .page-main {
        max-width: var(--page-max-width);
        width: 100%;
        min-width: 0;
        margin-inline: auto;
        padding: var(--space-5) var(--space-5) var(--space-6);
        box-sizing: border-box;
        /* Goes inert while the socket is down — see "Connection witness" below. */
        transition: opacity var(--motion-base) var(--ease-out),
                    filter var(--motion-base) var(--ease-out);
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
        max-width: 100%;
        min-width: 0;
        box-sizing: border-box;
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
        flex-wrap: wrap;
        justify-content: flex-end;
        align-items: center;
        gap: var(--space-1);
        min-width: 0;
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
      .navbar-links a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

      /* Footer — the page's visual stop AND the connection witness. */
      .page-footer {
        width: 100%;
        box-sizing: border-box;
        font-family: var(--font-display);
        font-size: var(--text-xs);
        color: var(--text-muted);
        border-top: 1px solid var(--rule);
        background: var(--bg);
        transition: background-color var(--motion-base) var(--ease-out),
                    border-color var(--motion-base) var(--ease-out);
      }
      .footer-inner {
        max-width: var(--page-max-width);
        width: 100%;
        margin-inline: auto;
        padding: var(--space-3) var(--space-5);
        box-sizing: border-box;
        display: flex;
        align-items: baseline;
        gap: var(--space-3);
        min-height: var(--footer-height);
      }
      .footer-mark { font-weight: 600; color: var(--text-subtle); }

      /* === Connection witness ==========================================
         LiveView stamps exactly one class set on the LiveView ROOT CONTAINER
         (`View#setContainerClasses`, deps/phoenix_live_view/assets/js/
         phoenix_live_view/view.ts; names in constants.ts): `phx-connected`
         when joined, `phx-loading` while (re)joining, and on a drop
         `phx-loading phx-error phx-client-error` (socket down) or
         `... phx-server-error` (join/crash). An error therefore ALSO carries
         `phx-loading`, hence the `:not(.phx-error)` guard on the joining
         state. That container sits inside `.page-main`, so the chrome reads
         it with `:has()`.

         The 400ms `transition-delay` is the blip debounce: a drop shorter
         than that never reaches a painted frame. It gates the loud part
         (dimming) even under `prefers-reduced-motion`, which zeroes
         durations but not delays. */

      .conn-witness { display: grid; }
      .conn-state {
        grid-area: 1 / 1;
        letter-spacing: 0.02em;
        opacity: 0;
        visibility: hidden;
        transition: opacity var(--motion-base) var(--ease-out),
                    visibility var(--motion-base);
      }
      .conn-state-joining { color: var(--text-subtle); }
      .conn-state-dropped, .conn-state-unresponsive { color: var(--accent); }

      .page-shell:has(.phx-loading:not(.phx-error)) .page-main {
        opacity: 0.72;
        transition-delay: 400ms;
      }
      .page-shell:has(.phx-error) .page-main {
        opacity: 0.45;
        filter: grayscale(0.9);
        transition-delay: 400ms;
      }

      /* The statement must stay legible while the plane behind it is dimmed,
         so the footer leaves the dimmed column and pins to the viewport. */
      .page-shell:has(.phx-loading) .page-footer,
      .page-shell:has(.phx-error) .page-footer {
        position: fixed;
        inset-inline: 0;
        bottom: 0;
        z-index: 60;
        background: var(--surface);
        border-top-color: var(--rule-strong);
      }

      /* Connected is keyed positively off phx-connected, not off the
         absence of a phx class — before JS boots, no line is revealed at
         all, never a false "Connected" claim (the base `.conn-state` rule
         above already leaves it opacity:0/hidden). No debounce delay here:
         phx-connected and phx-loading/phx-error are mutually exclusive
         (LiveView stamps exactly one set), so unlike the loud states below
         there is no blip to guard against — real signal, shown as soon as
         it's true. */
      .page-shell:has(.phx-connected) .conn-state-connected {
        opacity: 1;
        visibility: visible;
      }
      .page-shell:has(.phx-loading:not(.phx-error)) .conn-state-joining,
      .page-shell:has(.phx-client-error) .conn-state-dropped,
      .page-shell:has(.phx-server-error) .conn-state-unresponsive {
        opacity: 1;
        visibility: visible;
        transition-delay: 400ms;
      }

      /* === Operator dashboard (Harness.Dashboard.Live) — rehome === */

      table { border-collapse: collapse; width: 100%; margin-block: var(--space-3); }
      th, td { text-align: left; padding: var(--space-2) var(--space-3); border-bottom: 1px solid var(--rule-strong); }
      th { font-weight: 600; color: var(--text-subtle); font-family: var(--font-display); font-size: var(--text-sm); }

      /* Transposed agent ledger (Harness.Dashboard.KPILive :agents) — metrics
         down the rows, one column per agent. The leading metric-name column is a
         sticky row header so it stays visible while the agent columns scroll. */
      .kpi-matrix th[scope="row"] {
        text-align: left;
        white-space: nowrap;
        color: var(--text);
        position: sticky;
        left: 0;
        background: var(--surface);
      }
      .kpi-matrix thead th[scope="col"] { text-align: left; }
      .kpi-matrix thead th[scope="col"]:first-child {
        position: sticky;
        left: 0;
        background: var(--surface);
      }

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
        border: 1px solid var(--rule-strong);
        border-radius: 0.25rem;
        font-size: var(--text-sm);
      }
      .topbar select {
        background: var(--surface);
        color: var(--text);
        border: 1px solid var(--rule-strong);
        padding: var(--space-1) var(--space-2);
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        border-radius: 0.25rem;
      }
      .topbar a:focus-visible,
      .topbar select:focus-visible {
        outline: 2px solid var(--accent);
        outline-offset: 2px;
      }
      .count { font-size: var(--text-sm); color: var(--text-subtle); }
      .history-toggle-btn:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

      /* Task-facet pivot (Harness.Dashboard.KPILive, Task 225) — facet filter
         pills, per-facet cards, and the scout's verdict beside the fact ledger. */
      .facet-filter {
        display: flex;
        flex-wrap: wrap;
        gap: var(--space-2);
        margin-block: var(--space-3);
      }
      button.facet-pill {
        appearance: none;
        background: var(--surface);
        color: var(--text-subtle);
        border: 1px solid var(--rule);
        border-radius: 0.25rem;
        padding: var(--space-1) var(--space-3);
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        cursor: pointer;
        transition: color var(--motion-fast) var(--ease-out);
      }
      button.facet-pill:hover { color: var(--text); }
      button.facet-pill.active {
        color: var(--text);
        border-color: var(--accent);
        background: var(--accent-soft);
      }
      .facet-card { margin-block: var(--space-4); }
      .facet-head {
        display: flex;
        flex-wrap: wrap;
        gap: var(--space-2) var(--space-3);
        align-items: baseline;
      }
      .facet-head strong { font-family: var(--font-mono); }
      .scout-winner { font-size: var(--text-sm); color: var(--verdict-pass); }
      .scout-reasoning {
        margin-block: var(--space-2);
        color: var(--text-subtle);
        font-size: var(--text-sm);
        max-width: 70ch;
      }
      tr.winner { background: rgba(79, 155, 106, 0.12); }
      tr.winner td:first-child { box-shadow: inset 0.2rem 0 0 var(--verdict-pass); }

      /* Kill affordance — single --accent signal as a terminal-state cue */
      .kill-btn {
        background: transparent;
        color: var(--accent);
        border: 1px solid var(--accent);
        border-radius: 0.25rem;
        padding: var(--space-1) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        font-weight: 600;
        cursor: pointer;
        transition: background-color var(--motion-fast) var(--ease-out);
      }
      .kill-btn:hover { background: var(--accent-soft); }

      /* Delete affordance — muted (history cleanup), quieter than the --accent kill cue */
      .delete-btn {
        background: transparent;
        color: var(--text-muted);
        border: 1px solid var(--rule-strong);
        border-radius: 0.25rem;
        padding: var(--space-1) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        font-weight: 600;
        cursor: pointer;
        transition: color var(--motion-fast) var(--ease-out), border-color var(--motion-fast) var(--ease-out);
      }
      .delete-btn:hover { color: var(--text-subtle); border-color: var(--text-muted); }

      /* Resume affordance — recovery re-dispatch off a failed run. Verdict-info
         tint reads "actionable, non-destructive", distinct from the --accent kill
         cue and the muted delete cleanup. The Escalate variant shares the style;
         the label + confirm copy carry the difference. */
      .resume-btn {
        background: transparent;
        color: var(--verdict-info);
        border: 1px solid var(--verdict-info);
        border-radius: 0.25rem;
        padding: var(--space-1) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        font-weight: 600;
        cursor: pointer;
        transition: background-color var(--motion-fast) var(--ease-out);
      }
      .resume-btn:hover { background: rgba(74, 127, 168, 0.16); }

      /* Re-land affordance — zero-token git re-enqueue of a land-capped train.
         Verdict-pass tint mirrors the "landed" badge the re-land is reaching for. */
      .reland-btn {
        background: transparent;
        color: var(--verdict-pass);
        border: 1px solid var(--verdict-pass);
        border-radius: 0.25rem;
        padding: var(--space-1) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        font-weight: 600;
        cursor: pointer;
        transition: background-color var(--motion-fast) var(--ease-out);
      }
      .reland-btn:hover { background: rgba(79, 155, 106, 0.16); }
      .kill-btn:focus-visible,
      .delete-btn:focus-visible,
      .resume-btn:focus-visible,
      .reland-btn:focus-visible {
        outline: 2px solid var(--accent);
        outline-offset: 2px;
      }

      /* Action cell can stack up to three affordances on a failed/blocked row
         (Resume · Escalate · Delete) — flex-gap keeps them from butting together. */
      .row-actions { display: flex; flex-wrap: wrap; gap: var(--space-2); }

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

      /* Run stage stepper (Task 312) */
      .run-stage-stepper {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--space-1);
        list-style: none;
        margin: 0;
        padding: 0;
      }
      .run-stage-step {
        display: inline-flex;
        align-items: center;
        gap: var(--space-1);
        font-size: var(--text-xs);
        letter-spacing: 0.02em;
      }
      .run-stage-sep { color: var(--text-subtle); margin-inline: var(--space-1); }
      .run-stage-step-complete { color: var(--text-muted); }
      .run-stage-step-complete .run-stage-label::before {
        content: "✓ ";
        color: var(--verdict-ok);
      }
      .run-stage-step-current { color: var(--accent); font-weight: 600; }
      .run-stage-step-future { color: var(--text-subtle); opacity: 0.55; }
      .run-agent {
        display: inline-flex;
        align-items: center;
        gap: var(--space-2);
      }
      .run-agent-active { color: var(--accent); font-weight: 600; }

      /* Low-traffic run metadata (os pid / reason / worktree path) tucked behind
         a disclosure so the high-signal rows above stay compact. */
      .run-internals {
        margin-block: var(--space-2);
        font-size: var(--text-sm);
      }
      .run-internals > summary {
        cursor: pointer;
        color: var(--text-subtle);
        font-family: var(--font-mono);
      }
      .run-internals > summary:hover { color: var(--text); }
      .run-internals .field { margin-block-start: var(--space-2); }

      .run-failure {
        margin-block: var(--space-3);
        padding: var(--space-3);
        border: 1px solid var(--rule);
        border-radius: 0.4rem;
        background: var(--surface);
      }
      .run-failure h2 {
        margin: 0 0 var(--space-2);
        font-size: var(--text-md);
      }
      .run-failure p { margin: 0 0 var(--space-2); font-size: var(--text-sm); }
      .run-failure details { font-size: var(--text-sm); }
      .run-failure details summary {
        cursor: pointer;
        color: var(--text-subtle);
        font-family: var(--font-mono);
      }
      .run-failure details pre {
        margin-top: var(--space-2);
        white-space: pre-wrap;
      }

      /* === Task details (the focused run's roadmap task) === */

      .task-details { margin-block: var(--space-4); }
      .task-details .config-pill { margin-right: var(--space-2); }
      .task-subhead {
        margin: var(--space-3) 0 var(--space-1);
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }
      .task-criteria {
        margin: 0;
        padding-left: var(--space-5);
        font-size: var(--text-sm);
        color: var(--text-subtle);
      }
      .task-criteria li { margin-block: var(--space-1); }
      .task-body { margin-top: var(--space-3); }
      .task-body summary {
        cursor: pointer;
        font-size: var(--text-sm);
        color: var(--accent);
      }
      .task-body pre {
        margin-top: var(--space-2);
        padding: var(--space-3);
        background: var(--surface-2);
        border: 1px solid var(--rule);
        border-radius: 0.4rem;
        font-size: var(--text-sm);
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      /* === Changed files / run diff (Harness.RunDiff) === */

      .changed-files { margin-block: var(--space-4); }

      .cf-head {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
        gap: var(--space-4);
        flex-wrap: wrap;
        padding-bottom: var(--space-2);
        margin-bottom: var(--space-3);
        border-bottom: 1px solid var(--rule);
      }
      .cf-title { font-family: var(--font-display); font-size: var(--text-md); color: var(--text); }
      .cf-count {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        border: 1px solid var(--rule);
        border-radius: 999px;
        padding: 0 var(--space-2);
        margin-left: var(--space-1);
      }
      .cf-totals { display: flex; align-items: center; gap: var(--space-3); font-family: var(--font-mono); font-size: var(--text-sm); }
      .cf-add { color: var(--diff-add-fg); }
      .cf-del { color: var(--diff-del-fg); }

      /* Aggregate proportion bar */
      .cf-statbar {
        display: inline-flex;
        width: 8rem;
        height: 0.5rem;
        border-radius: 999px;
        overflow: hidden;
        background: var(--surface-2);
        border: 1px solid var(--rule);
      }
      .cf-statbar-add { background: var(--diff-add-edge); }
      .cf-statbar-del { background: var(--diff-del-edge); }

      /* === Agent-KPI page (stat strip, section panels, proportion bars) === */
      .kpi-strip {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr));
        gap: var(--space-3);
        margin-block: var(--space-4);
      }
      .kpi-stat {
        display: flex;
        flex-direction: column;
        gap: var(--space-1);
        padding: var(--space-3) var(--space-4);
        border: 1px solid var(--rule);
        border-radius: 0.5rem;
        background: var(--surface);
      }
      .kpi-stat-num { font-family: var(--font-mono); font-size: var(--text-lg); color: var(--text); }
      .kpi-stat-label {
        font-size: var(--text-xs);
        color: var(--text-muted);
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }
      .kpi-stat.is-zero { background: transparent; }
      .kpi-stat.is-zero .kpi-stat-num,
      .kpi-stat.is-zero .kpi-stat-label { color: var(--text-muted); font-weight: 400; }
      .fleet-counts { grid-template-columns: repeat(auto-fit, minmax(7rem, 1fr)); }

      .kpi-section {
        margin-block: var(--space-5);
        padding: var(--space-3) var(--space-4) var(--space-4);
        border: 1px solid var(--rule);
        border-radius: 0.5rem;
        background: var(--surface);
      }
      .kpi-section > table { margin-top: 0; }

      .kpi-cell { display: flex; align-items: center; gap: var(--space-2); }
      .kpi-pct { font-family: var(--font-mono); min-width: 2.4rem; }
      .kpi-bar {
        display: inline-flex;
        flex: 1;
        min-width: 2.5rem;
        max-width: 4.5rem;
        height: 0.5rem;
        border-radius: 999px;
        overflow: hidden;
        background: var(--surface-2);
        border: 1px solid var(--rule);
      }
      .kpi-bar-fill { height: 100%; border-radius: 999px; transition: width var(--motion-fast) var(--ease-out); }

      .tone-pass { color: var(--verdict-pass); }
      .tone-info { color: var(--verdict-info); }
      .tone-warn { color: var(--verdict-warn); }
      .kpi-bar-fill.tone-pass { background: var(--verdict-pass); }
      .kpi-bar-fill.tone-info { background: var(--verdict-info); }
      .kpi-bar-fill.tone-warn { background: var(--verdict-warn); }

      /* Jump-nav between page sections (KPI + run-detail); sticky under the
         navbar so it stays reachable while a long section scrolls */
      .kpi-nav,
      .run-detail-nav {
        position: sticky;
        top: var(--navbar-height);
        z-index: 2;
        display: flex;
        flex-wrap: wrap;
        gap: var(--space-2);
        margin-block: var(--space-3);
        padding-block: var(--space-2);
        background: var(--bg);
      }
      .kpi-nav a,
      .run-detail-nav a {
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        text-decoration: none;
        padding: 0.15em 0.7em;
        border: 1px solid var(--rule);
        border-radius: 999px;
        color: var(--text-subtle);
      }
      .kpi-nav a:hover,
      .run-detail-nav a:hover { color: var(--text); border-color: var(--accent); }
      .kpi-nav a:focus-visible,
      .run-detail-nav a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

      /* Wrap a wide table (the ledger's dynamic rating columns) so it scrolls in place */
      .table-scroll { overflow-x: auto; max-width: 100%; min-width: 0; width: 100%; }
      .run-detail-disclosure { max-width: 24rem; }
      .run-detail-disclosure summary {
        max-width: 24rem;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        cursor: pointer;
      }
      .run-detail-disclosure div { margin-top: var(--space-2); white-space: normal; overflow-wrap: anywhere; }
      .review-warning-mark {
        display: block;
        margin-top: var(--space-1);
        color: var(--verdict-warn);
        font-family: var(--font-mono);
        font-size: var(--text-xs);
      }
      .has-review-warning { background: rgba(184, 123, 53, 0.08); }
      .review-testimony.has-review-warning { border-color: var(--verdict-warn); }
      .review-fact pre { white-space: pre-wrap; overflow-wrap: anywhere; }
      .kpi-section,
      .run-section { scroll-margin-top: calc(var(--navbar-height) + 3rem); }

      /* File rows */
      .cf-file {
        border: 1px solid var(--rule);
        border-radius: 0.4rem;
        background: var(--surface);
        margin-bottom: var(--space-2);
        overflow: hidden;
      }
      .cf-file[open] { border-color: rgba(230, 161, 75, 0.30); }
      .cf-file-head {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        padding: var(--space-2) var(--space-3);
        cursor: pointer;
        list-style: none;
      }
      .cf-file-head::-webkit-details-marker { display: none; }
      .cf-file-head::before {
        content: "›";
        color: var(--text-muted);
        transition: transform var(--motion-fast) var(--ease-out);
      }
      .cf-file[open] .cf-file-head::before { transform: rotate(90deg); }

      .cf-status {
        font-family: var(--font-mono);
        font-weight: 700;
        font-size: var(--text-xs);
        width: 1.2rem;
        text-align: center;
        flex: none;
      }
      .cf-status-added { color: var(--diff-add-edge); }
      .cf-status-deleted { color: var(--diff-del-edge); }
      .cf-status-modified { color: var(--accent); }
      .cf-status-renamed { color: var(--verdict-info); }

      .cf-path {
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        flex: 1;
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .cf-path-dir { color: var(--text-muted); }
      .cf-path-base { color: var(--text); font-weight: 600; }

      .cf-file-counts { display: flex; align-items: center; gap: var(--space-2); font-family: var(--font-mono); font-size: var(--text-xs); flex: none; }
      .cf-binary { color: var(--text-muted); font-family: var(--font-mono); font-size: var(--text-xs); }

      /* Five-square per-file mini-bar */
      .cf-squares { display: inline-flex; gap: 2px; }
      .cf-sq { width: 0.55rem; height: 0.55rem; border-radius: 1px; background: var(--surface-2); border: 1px solid var(--rule); }
      .cf-sq-add { background: var(--diff-add-edge); border-color: var(--diff-add-edge); }
      .cf-sq-del { background: var(--diff-del-edge); border-color: var(--diff-del-edge); }

      /* Diff body */
      .diff {
        border-top: 1px solid var(--rule);
        overflow-x: auto;
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        line-height: 1.5;
        background: var(--bg);
      }
      .dl { white-space: pre; padding: 0 var(--space-3); border-left: 2px solid transparent; }
      .dl-add { background: var(--diff-add-bg); border-left-color: var(--diff-add-edge); color: var(--text); }
      .dl-del { background: var(--diff-del-bg); border-left-color: var(--diff-del-edge); color: var(--text); }
      .dl-ctx { color: var(--text-subtle); }
      .dl-hunk {
        background: var(--surface-2);
        color: var(--verdict-info);
        position: sticky;
        left: 0;
        padding-block: 2px;
      }

      .cf-truncated, .cf-branch, .cf-note, .cf-empty {
        font-size: var(--text-xs);
        color: var(--text-muted);
        margin-block: var(--space-2);
      }
      .cf-branch code, .cf-truncated code { color: var(--text-subtle); }

      /* Live edited-files (in-progress run) */
      .cf-live-tag {
        display: inline-flex;
        align-items: center;
        gap: var(--space-1);
        font-size: var(--text-xs);
        color: var(--accent);
        text-transform: uppercase;
        letter-spacing: 0.06em;
        font-weight: 600;
      }
      .cf-live-dot {
        width: 0.5rem;
        height: 0.5rem;
        border-radius: 999px;
        background: var(--accent);
        animation: cf-pulse 1.4s var(--ease-in-out) infinite;
      }
      .changed-files-live .cf-chips { list-style: none; margin: var(--space-2) 0 0; padding: 0; display: flex; flex-wrap: wrap; gap: var(--space-2); }
      .cf-chip { border: 1px solid var(--rule); border-radius: 0.3rem; background: var(--surface); padding: var(--space-1) var(--space-3); }
      .cf-edits {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        margin-left: var(--space-2);
      }

      @keyframes cf-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.25; } }

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

      /* Chat index — session list */
      .chat-index { display: flex; flex-direction: column; gap: var(--space-4); }
      .session-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: var(--space-2); }
      .session-card {
        border: 1px solid var(--rule);
        border-radius: 0.4rem;
        background: var(--surface);
        transition: border-color var(--motion-fast) var(--ease-out);
      }
      .session-card:hover { border-color: var(--accent); }
      .session-link {
        display: flex;
        flex-direction: column;
        gap: var(--space-1);
        padding: var(--space-3);
        text-decoration: none;
      }
      .session-link:hover { text-decoration: none; }
      .session-label {
        font-family: var(--font-display);
        font-size: var(--text-md);
        color: var(--text);
      }
      .session-meta {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: var(--space-1) var(--space-3);
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
      }
      .session-live {
        color: var(--verdict-pass);
        text-transform: uppercase;
        letter-spacing: 0.06em;
        font-weight: 600;
      }
      .session-id { color: var(--text-subtle); }

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
      /* Stop button — outlined --accent terminal-state cue (mirrors .kill-btn),
         overriding the filled .composer button so Stop reads as an interrupt,
         not a primary action. Occupies the same grid cell Send vacates. */
      .composer .stop-btn { background: transparent; color: var(--accent); border: 1px solid var(--accent); }
      .composer .stop-btn:hover { background: var(--accent-soft); }

      .playbook-bar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--space-2);
        margin-bottom: var(--space-3);
      }
      .playbook-bar .label {
        color: var(--text-muted);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        font-weight: 600;
        margin-right: var(--space-1);
      }
      .playbook-chip {
        background: var(--surface);
        color: var(--text);
        border: 1px solid var(--rule);
        border-radius: 999px;
        padding: var(--space-1) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        cursor: pointer;
        transition: border-color var(--motion-fast) var(--ease-out),
          background-color var(--motion-fast) var(--ease-out);
      }
      .playbook-chip:hover {
        border-color: var(--accent);
        background: var(--accent-soft);
      }

      .empty-state {
        color: var(--text-muted);
        font-family: var(--font-display);
        font-size: var(--text-md);
        padding-block: var(--space-6);
        text-align: center;
        border: 1px dashed var(--rule);
        border-radius: 0.5rem;
      }

      /* --- Run-detail transcript_view (Task 87) --------------------------- */

      .transcript-view {
        display: flex;
        flex-direction: column;
        gap: var(--space-3);
        margin-block: var(--space-3);
        /* The transcript flows with the page — one natural scrollbar, no
           scroll-within-scroll trap. Navigation back to the metadata/task/diff
           is the sticky .run-detail-nav, not a bounded pane. */
      }
      .transcript-empty {
        color: var(--text-muted);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        padding-block: var(--space-4);
      }
      .transcript-toggle {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        margin-block: var(--space-2);
      }
      .transcript-toggle a {
        color: var(--text-muted);
        text-decoration: underline dotted;
        text-underline-offset: 0.2rem;
      }
      .transcript-toggle a:hover { color: var(--text); }

      .transcript-chrome {
        display: flex;
        flex-direction: column;
        gap: var(--space-1);
        margin-block: var(--space-2) var(--space-3);
        padding: var(--space-2) var(--space-3);
        border: 1px solid var(--rule);
        border-radius: 0.35rem;
        background: var(--surface);
      }
      .transcript-summary {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        margin: 0;
      }
      .transcript-activity {
        font-family: var(--font-display);
        font-size: var(--text-sm);
        color: var(--text);
        margin: 0;
      }
      .transcript-heartbeat {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        margin: 0;
      }

      .eyebrow {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        letter-spacing: 0.03em;
        text-transform: uppercase;
        margin: 0;
        padding-left: var(--space-2);
        border-left: 2px solid var(--rule);
      }
      .eyebrow-kind { color: var(--text); }

      .plain-chunk {
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        line-height: 1.5;
        color: var(--text);
        background: var(--bg);
        border: 1px solid var(--rule);
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-3);
        white-space: pre-wrap;
        word-break: break-word;
        overflow-x: auto;
      }

      .transcript-unknown {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        background: rgba(255,255,255,0.02);
        border: 1px dashed var(--rule);
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-3);
      }
      .transcript-unknown > summary { cursor: pointer; }
      .transcript-unknown[open] { color: var(--text); }
      .transcript-unknown pre {
        margin-block-start: var(--space-2);
        white-space: pre-wrap;
        word-break: break-word;
      }

      /* Collapsed reasoning (chain-of-thought) — dim + secondary to assistant
         text, so a token-heavy thought stays out of the way until expanded. */
      .transcript-thought {
        font-size: var(--text-xs);
        color: var(--text-muted);
      }
      .transcript-thought > summary {
        cursor: pointer;
        font-style: italic;
        letter-spacing: 0.02em;
      }
      .transcript-thought[open] { color: var(--text); }
      .thought-text {
        margin-block-start: var(--space-2);
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        line-height: 1.5;
        white-space: pre-wrap;
        word-break: break-word;
        opacity: 0.85;
      }

      /* === Settings page — operator controls (Tasks 109/110) === */
      .settings {
        display: flex;
        flex-direction: column;
        gap: var(--space-5);
        max-width: 760px;
      }
      .settings-head {
        border-bottom: 1px solid var(--rule);
        padding-bottom: var(--space-3);
      }
      .settings-head h1 { margin: 0 0 var(--space-1); }
      .settings-sub { margin: 0; color: var(--text-subtle); font-size: var(--text-sm); }

      /* In-page section nav: one tab per card group, replacing the long scroll. */
      .settings-tabs {
        display: flex;
        flex-wrap: wrap;
        gap: var(--space-1);
        border-bottom: 1px solid var(--rule);
      }
      .settings-tab {
        appearance: none;
        background: transparent;
        border: 0;
        border-bottom: 2px solid transparent;
        margin-bottom: -1px;
        padding: var(--space-2) var(--space-3);
        color: var(--text-subtle);
        font: inherit;
        font-size: var(--text-sm);
        cursor: pointer;
        transition: color var(--motion-fast) var(--ease-out),
          border-color var(--motion-fast) var(--ease-out);
      }
      .settings-tab:hover { color: var(--text); }
      .settings-tab[data-active="true"] {
        color: var(--text);
        border-bottom-color: var(--accent);
      }

      /* Panel = the card stack for one tab; hidden panels stay in the DOM. */
      .settings-panel {
        display: flex;
        flex-direction: column;
        gap: var(--space-5);
      }
      .settings-panel[hidden] { display: none; }

      .setting-card {
        background: var(--surface);
        border: 1px solid var(--rule);
        border-radius: 0.6rem;
        padding: var(--space-5);
        animation: settings-rise var(--motion-base) var(--ease-out) both;
      }
      .setting-card:nth-of-type(2) { animation-delay: 50ms; }
      .setting-card h2 { margin: 0 0 var(--space-2); font-size: var(--text-lg); }

      /* Master card: an accent rail down the left edge that lights when armed. */
      .setting-master { position: relative; overflow: hidden; padding-left: calc(var(--space-5) + 3px); }
      .setting-master::before {
        content: "";
        position: absolute;
        left: 0; top: 0; bottom: 0;
        width: 3px;
        background: var(--rule);
        transition: background var(--motion-base) var(--ease-out);
      }
      .setting-master[data-on="true"]::before { background: var(--accent); }
      .setting-master-row {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: var(--space-5);
      }
      .setting-desc {
        margin: 0 0 var(--space-3);
        color: var(--text-subtle);
        font-size: var(--text-sm);
        max-width: 52ch;
        line-height: 1.5;
      }
      .setting-status {
        display: flex;
        align-items: center;
        gap: var(--space-2);
        margin: 0;
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-subtle);
      }
      .setting-warn {
        margin: var(--space-4) 0 0;
        padding: var(--space-2) var(--space-3);
        background: var(--accent-soft);
        border: 1px solid var(--accent);
        border-radius: 0.4rem;
        color: var(--text);
        font-size: var(--text-sm);
      }
      .setting-section-title {
        margin: 0;
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        color: var(--text-muted);
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }

      /* State pill — neutral by default, verdict-green when dispatching, amber when armed. */
      .pill {
        display: inline-flex;
        align-items: center;
        gap: 0.45em;
        padding: 0.1rem 0.6rem;
        border-radius: 999px;
        border: 1px solid var(--rule);
        background: var(--surface-2);
        color: var(--text-subtle);
        font-family: var(--font-display);
        font-size: var(--text-xs);
        font-weight: 600;
        letter-spacing: 0.01em;
      }
      .pill::before {
        content: "";
        width: 0.45em; height: 0.45em;
        border-radius: 50%;
        background: currentColor;
      }
      .pill[data-state="on"] { color: var(--verdict-pass); border-color: var(--verdict-pass); }
      .pill[data-state="armed"] { color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }
      .pill[data-state="off"] { color: var(--text-muted); }

      /* Toggle switch — track + thumb, amber when checked. role="switch" button. */
      .toggle {
        appearance: none;
        flex: none;
        width: 3rem;
        height: 1.6rem;
        margin: 0;
        padding: 0;
        border: 1px solid var(--rule-strong);
        border-radius: 999px;
        background: var(--surface-2);
        cursor: pointer;
        position: relative;
        transition: background var(--motion-base) var(--ease-out),
          border-color var(--motion-base) var(--ease-out);
      }
      .toggle::after {
        content: "";
        position: absolute;
        top: 50%;
        left: 0.2rem;
        transform: translateY(-50%);
        width: 1.1rem; height: 1.1rem;
        border-radius: 50%;
        background: var(--text-subtle);
        transition: transform var(--motion-base) var(--ease-out),
          background var(--motion-base) var(--ease-out);
      }
      .toggle[aria-checked="true"] { background: var(--accent-soft); border-color: var(--accent); }
      .toggle[aria-checked="true"]::after { transform: translate(1.4rem, -50%); background: var(--accent); }
      .toggle:hover { border-color: var(--text-muted); }
      .toggle[aria-checked="true"]:hover { border-color: var(--accent); }
      .toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

      .project-list { list-style: none; margin: var(--space-3) 0 0; padding: 0; }
      .project-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--space-4);
        padding: var(--space-3) 0;
        border-top: 1px solid var(--rule);
      }
      .project-row:first-child { border-top: 0; }
      .project-id { display: flex; align-items: center; gap: var(--space-3); }
      .project-name { font-family: var(--font-mono); font-size: var(--text-sm); color: var(--text); }
      .project-empty { color: var(--text-muted); font-size: var(--text-sm); padding: var(--space-3) 0; }

      /* Per-agent control matrix (Task 182): captioned enabled + reviewer toggles. */
      .agent-controls { display: flex; align-items: flex-end; gap: var(--space-4); flex: none; }
      .agent-model-form { display: flex; align-items: center; gap: var(--space-2); flex-wrap: wrap; }
      .catalog-row { align-items: flex-start; flex-wrap: wrap; }
      .catalog-row > .project-id { flex: 1 1 14rem; }
      .catalog-controls { justify-content: flex-end; flex-wrap: wrap; }
      .catalog-filter { flex: 1 1 11rem; justify-content: flex-end; }
      /* Model membership universe: wraps within the card instead of overflowing right. */
      .catalog-models {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--space-2) var(--space-4);
        flex-basis: 100%;
      }
      .catalog-model-toggle {
        appearance: none;
        display: inline-flex;
        align-items: center;
        gap: var(--space-2);
        padding: 0;
        border: 0;
        background: transparent;
        color: inherit;
        font: inherit;
        cursor: pointer;
      }
      .catalog-model-toggle .toggle {
        width: 2.4rem;
        height: 1.3rem;
        pointer-events: none;
      }
      .catalog-model-toggle .toggle::after { width: 0.9rem; height: 0.9rem; }
      .catalog-model-toggle .toggle[aria-checked="true"]::after { transform: translate(1.1rem, -50%); }
      .catalog-model-toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 0.35rem; }
      .agent-control { display: flex; flex-direction: column; align-items: center; gap: var(--space-1); }
      .agent-control-caption {
        font-family: var(--font-mono);
        font-size: var(--text-xs);
        text-transform: uppercase;
        letter-spacing: 0.04em;
        color: var(--text-muted);
      }

      /* Config inspector (Task 127) — read-only resolved-config rows + provenance pills. */
      .config-section { margin-top: var(--space-4); }
      .config-section:first-of-type { margin-top: var(--space-3); }
      .config-section-title {
        margin: 0 0 var(--space-2);
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        color: var(--text-subtle);
      }
      .config-rows { margin: 0; }
      .config-row {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
        gap: var(--space-4);
        padding: var(--space-2) 0;
        border-top: 1px solid var(--rule);
      }
      .config-row:first-child { border-top: 0; }
      .config-key { margin: 0; font-family: var(--font-mono); font-size: var(--text-sm); color: var(--text); }
      .config-val { display: flex; align-items: center; gap: var(--space-3); margin: 0; min-width: 0; }
      .config-val code {
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        color: var(--text-subtle);
        overflow-wrap: anywhere;
      }
      .config-pill {
        flex: none;
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        padding: 0.1em 0.55em;
        border-radius: 999px;
        border: 1px solid var(--rule);
        color: var(--text-muted);
        letter-spacing: 0.01em;
      }
      .config-pill[data-prov="config"] { color: var(--accent); border-color: var(--accent); }
      .config-pill[data-prov="env"] { color: var(--verdict-pass); border-color: var(--verdict-pass); }

      /* The "knob": the env var that overrides a key, shown on every applicable row. */
      .config-knob {
        flex: none;
        font-family: var(--font-mono);
        font-size: var(--text-sm);
        padding: 0.05em 0.45em;
        border-radius: var(--radius-sm, 4px);
        border: 1px dashed var(--rule);
        background: var(--surface-2);
        color: var(--text-subtle);
        white-space: nowrap;
      }

      /* Inline legend explaining the provenance pills + the knob chip. */
      .config-legend {
        list-style: none;
        display: flex;
        flex-wrap: wrap;
        gap: var(--space-2) var(--space-4);
        margin: 0 0 var(--space-3);
        padding: var(--space-3) 0 0;
        border-top: 1px solid var(--rule);
        font-size: var(--text-sm);
        color: var(--text-subtle);
      }
      .config-legend li { display: inline-flex; align-items: center; gap: var(--space-2); }

      /* Shared operator feedback: persistent runtime warnings + transient event notices. */
      .operator-flash {
        display: grid;
        gap: var(--space-2);
        margin: var(--space-3) 0 0;
      }
      .operator-flash:empty {
        margin: 0;
        gap: 0;
      }

      .operator-notice {
        padding: var(--space-2) var(--space-3);
        border: 1px solid var(--rule);
        border-radius: 0.4rem;
        font-size: var(--text-sm);
        color: var(--text);
      }
      .operator-notice[data-persistent="true"] { font-weight: 650; }
      .operator-notice[data-kind="ok"] { border-color: var(--verdict-pass); background: var(--surface-2); }
      .operator-notice[data-kind="error"],
      .operator-notice[data-kind="warning"] { border-color: var(--accent); background: var(--accent-soft); }

      /* Cron schedule preset picker (boot-applied; Task 111). */
      .setting-schedule { display: flex; align-items: center; gap: var(--space-3); margin-top: var(--space-4); flex-wrap: wrap; }
      .setting-schedule form { display: flex; align-items: center; gap: var(--space-2); }
      .setting-schedule label { color: var(--text-muted); font-size: var(--text-sm); }
      .setting-schedule select {
        background: var(--surface);
        color: var(--text);
        border: 1px solid var(--rule);
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-3);
        font-family: var(--font-mono);
        font-size: var(--text-sm);
      }
      .setting-schedule select:focus { outline: 1px solid var(--accent); outline-offset: 1px; }

      /* Dispatch-now action row in the master card. */
      .setting-actions { display: flex; align-items: center; gap: var(--space-3); margin-top: var(--space-4); }
      .btn-dispatch {
        appearance: none;
        background: transparent;
        color: var(--accent);
        border: 1px solid var(--accent);
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        font-weight: 600;
        cursor: pointer;
      }
      .btn-dispatch:hover { background: var(--accent-soft); }
      .btn-dispatch:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
      .setting-hint { color: var(--text-muted); font-size: var(--text-sm); }

      /* Landing card — a per-project form row (policy select + target branch + save). */
      .landing-form, .reviewer-form {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        width: 100%;
        flex-wrap: wrap;
      }
      .landing-form .project-id, .reviewer-form .project-id { flex: 1 1 auto; }
      /* Shared control chrome for every settings form — selects + text inputs
         alike — so a control never falls back to native browser styling.
         (There is no utility framework here; styling is selector-explicit.) */
      .landing-form select, .landing-form input[type="text"],
      .reviewer-form select, .reviewer-form input[type="text"],
      .agent-model-form select, .agent-model-form input[type="text"] {
        background: var(--surface);
        color: var(--text);
        border: 1px solid var(--rule);
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-3);
        font-family: var(--font-mono);
        font-size: var(--text-sm);
      }
      /* Replace the native OS dropdown widget with an on-brand caret so every
         select matches the inputs instead of falling back to browser chrome. */
      .landing-form select, .reviewer-form select, .agent-model-form select {
        appearance: none;
        -webkit-appearance: none;
        padding-right: calc(var(--space-3) + 1rem);
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%238a90a0' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
        background-repeat: no-repeat;
        background-position: right var(--space-3) center;
      }
      .landing-form select:focus, .landing-form input[type="text"]:focus,
      .reviewer-form select:focus, .reviewer-form input[type="text"]:focus,
      .agent-model-form select:focus, .agent-model-form input[type="text"]:focus {
        outline: 1px solid var(--accent);
        outline-offset: 1px;
      }
      .btn-save {
        appearance: none;
        background: var(--surface-2);
        color: var(--text);
        border: 1px solid var(--rule);
        border-radius: 0.35rem;
        padding: var(--space-2) var(--space-3);
        font-family: var(--font-display);
        font-size: var(--text-sm);
        font-weight: 600;
        cursor: pointer;
      }
      .btn-save:hover { border-color: var(--accent); }
      .btn-save:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

      /* === A/B compare (Harness.Dashboard.CompareLive, Task 81) === */

      /* Launch form */
      .compare-launch { display: flex; flex-direction: column; gap: var(--space-5); max-width: 640px; }
      .compare-launch-head { border-bottom: 1px solid var(--rule); padding-bottom: var(--space-3); }
      .compare-launch-head h1 { margin: 0 0 var(--space-1); }
      .compare-form { display: flex; flex-direction: column; gap: var(--space-4); }
      .compare-field { display: flex; flex-direction: column; gap: var(--space-2); }
      .compare-field > span, .compare-field > legend {
        font-family: var(--font-display); font-size: var(--text-sm); font-weight: 600; color: var(--text-subtle);
      }
      .compare-field input[type="text"], .compare-field select {
        background: var(--surface); color: var(--text); border: 1px solid var(--rule);
        border-radius: 0.35rem; padding: var(--space-2) var(--space-3);
        font-family: var(--font-mono); font-size: var(--text-sm);
      }
      .compare-field input[type="text"]:focus, .compare-field select:focus { outline: 1px solid var(--accent); outline-offset: 1px; }
      .compare-hint { font-weight: 400; color: var(--text-muted); }
      .compare-adapters { border: 1px solid var(--rule); border-radius: 0.5rem; padding: var(--space-3) var(--space-4); }
      .compare-adapter-check {
        display: inline-flex; align-items: center; gap: var(--space-2);
        margin-right: var(--space-4); font-family: var(--font-mono); font-size: var(--text-sm);
      }
      .compare-submit {
        align-self: flex-start; background: var(--accent); color: #14110a; border: 0;
        border-radius: 0.35rem; padding: var(--space-2) var(--space-5);
        font-family: var(--font-display); font-size: var(--text-md); font-weight: 600; cursor: pointer;
        transition: opacity var(--motion-fast) var(--ease-out);
      }
      .compare-submit:hover { opacity: 0.9; }

      /* Full-bleed breakout — the side-by-side grid earns the whole viewport,
         escaping .page-main's centered max-width. */
      .compare-bleed {
        width: 100vw;
        margin-left: calc(50% - 50vw);
        padding-inline: var(--space-5);
        box-sizing: border-box;
        display: flex;
        flex-direction: column;
        gap: var(--space-5);
      }
      .compare-head { display: flex; align-items: flex-start; justify-content: space-between; gap: var(--space-4); }
      .compare-head h1 { margin: var(--space-1) 0 0; }
      .compare-back { font-family: var(--font-display); font-size: var(--text-sm); color: var(--text-subtle); text-decoration: none; }
      .compare-back:hover { color: var(--text); }
      .compare-id { font-family: var(--font-mono); font-size: var(--text-xs); color: var(--text-muted); }

      .compare-grid {
        display: grid;
        grid-template-columns: repeat(var(--lanes, 2), minmax(0, 1fr));
        gap: var(--space-4);
        align-items: start;
      }
      .compare-lane {
        display: flex;
        flex-direction: column;
        border: 1px solid var(--rule);
        border-radius: 0.6rem;
        background: var(--surface);
        overflow: hidden;
        transition: border-color var(--motion-base) var(--ease-out);
      }
      .compare-lane.is-active { border-color: var(--accent); }

      /* Lane header doubles as the transcript-tab control — a bare button styled
         as a header, focus restyled to the design vocabulary (no UA ring). */
      .compare-lane-head {
        appearance: none;
        display: flex; align-items: center; justify-content: space-between; gap: var(--space-3);
        width: 100%; cursor: pointer; text-align: left;
        background: var(--surface-2); border: 0; border-bottom: 1px solid var(--rule);
        padding: var(--space-3) var(--space-4);
        font: inherit; color: var(--text);
        transition: background var(--motion-fast) var(--ease-out);
      }
      .compare-lane-head:hover { background: var(--rule); }
      .compare-lane.is-active .compare-lane-head { box-shadow: inset 0 -2px 0 var(--accent); }
      .compare-lane-head:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
      .compare-lane-name { font-family: var(--font-mono); font-size: var(--text-md); font-weight: 600; }

      /* Verdict cell — the dominant element of each lane. Pass and fail are
         deliberately asymmetric: fail is loud (filled wash, heavy edge, larger),
         pass is calm. Pending is muted and quiet. */
      .compare-verdict {
        display: flex; align-items: center; gap: var(--space-3);
        padding: var(--space-5) var(--space-4);
        font-family: var(--font-display);
      }
      .compare-verdict-mark { font-size: var(--text-2xl); line-height: 1; }
      .compare-verdict-text { font-size: var(--text-xl); font-weight: 600; letter-spacing: -0.01em; text-transform: lowercase; }
      .compare-verdict[data-verdict="pass"] { color: var(--verdict-pass); }
      .compare-verdict[data-verdict="pass"] .compare-verdict-text { font-weight: 500; }
      .compare-verdict[data-verdict="fail"] {
        color: var(--verdict-fail);
        background: var(--diff-del-bg);
        border-left: 3px solid var(--verdict-fail);
        padding-block: var(--space-6);
      }
      .compare-verdict[data-verdict="fail"] .compare-verdict-mark { font-size: 2.4rem; }
      .compare-verdict[data-verdict="fail"] .compare-verdict-text { font-weight: 700; }
      .compare-verdict[data-verdict="pending"] { color: var(--text-muted); }
      .compare-verdict[data-verdict="pending"] .compare-verdict-mark { animation: cf-pulse 1.4s var(--ease-in-out) infinite; }

      .compare-metrics { margin: 0; padding: var(--space-2) var(--space-4) var(--space-4); }
      .compare-metric {
        display: flex; align-items: baseline; justify-content: space-between; gap: var(--space-3);
        padding: var(--space-2) 0; border-top: 1px solid var(--rule);
      }
      .compare-metric:first-child { border-top: 0; }
      .compare-metric dt { color: var(--text-subtle); font-size: var(--text-sm); }
      .compare-metric dd { margin: 0; font-family: var(--font-mono); font-size: var(--text-sm); color: var(--text); }

      .compare-transcript { border-top: 1px solid var(--rule); padding-top: var(--space-3); }

      /* Motion keyframes — guarded by prefers-reduced-motion at the bottom */
      @keyframes settings-rise {
        from { opacity: 0; transform: translateY(0.5rem); }
        to   { opacity: 1; transform: none; }
      }
      @keyframes msg-arrive {
        from { opacity: 0; transform: translateY(0.4rem); }
        to   { opacity: 1; transform: none; }
      }
      @keyframes cursor-pulse {
        0%, 60% { opacity: 1; }
        61%, 100% { opacity: 0.15; }
      }

      @media (max-width: 900px) {
        .page-shell { grid-template-rows: auto 1fr auto; }
        .navbar { height: auto; min-height: var(--navbar-height); flex-wrap: wrap; gap: var(--space-2); padding: var(--space-2) var(--space-3); }
        .navbar-links { flex: 1 1 100%; justify-content: flex-start; max-width: 100%; }
        .navbar-links a { padding: var(--space-2); }
        .page-main { padding-inline: var(--space-3); }
        .run-table-scroll { overflow: visible; }
        .run-table, .run-table tbody, .run-table tr, .run-table td { display: block; width: 100%; box-sizing: border-box; }
        .run-table thead, .run-table caption { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
        .run-table { border: 0; }
        .run-table tr {
          margin-bottom: var(--space-3);
          border: 1px solid var(--rule);
          border-radius: 0.5rem;
          background: var(--surface);
          overflow: hidden;
        }
        .run-table td {
          display: grid;
          grid-template-columns: minmax(6rem, 32%) minmax(0, 1fr);
          gap: var(--space-3);
          padding: var(--space-2) var(--space-3);
          border-bottom: 1px solid var(--rule);
          overflow-wrap: anywhere;
        }
        .run-table td:last-child { border-bottom: 0; }
        .run-table td::before {
          content: attr(data-label);
          color: var(--text-muted);
          font-family: var(--font-display);
          font-size: var(--text-xs);
          font-weight: 600;
          letter-spacing: 0.04em;
          text-transform: uppercase;
        }
        .run-detail-disclosure, .run-detail-disclosure summary { max-width: 100%; min-width: 0; }
        .row-actions button, .row-actions a { min-height: 44px; }
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
