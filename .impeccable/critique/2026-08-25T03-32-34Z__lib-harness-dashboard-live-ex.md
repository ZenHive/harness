---
target: the harness operator dashboard (/harness)
total_score: 19
max_score: 40
na_heuristics:
p0_count: 2
p1_count: 3
timestamp: 2026-08-25T03-32-34Z
slug: lib-harness-dashboard-live-ex
---
# Design Critique — harness Operator Dashboard (`/harness`)

Method: dual-agent (A: design review · B: detector + browser evidence).
Target: `lib/harness/dashboard/live.ex` · live at `localhost:4018/harness` · Mode: Operate

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 2 | Topbar "1 repairing" vs row badge "reviewing"; no `<h1>`; every tab titled "Harness Dashboard"; nav active-state CSS never set |
| 2 | Match System / Real World | 2 | "repairing" wrong word for review gate; failure text is a double-escaped Erlang term; `Tokens 6555778` unformatted |
| 3 | User Control and Freedom | 2 | Recovery actions only on index rows, never on detail; hold/steer/dispatch absent from UI |
| 4 | Consistency and Standards | 2 | `cursor-grok-4.6-high` vs `Cursor Grok 4.6 High`; `.table-scroll` used by KPI/Explorer but not run tables |
| 5 | Error Prevention | 3 | Best score: confirm-gated token-spending actions with cost-naming copy; `landable?/3` hides Land. Deduction: Resume/Escalate adjacent + near-identical |
| 6 | Recognition Rather Than Recall | 2 | 26-char run id is the row identity and the page heading |
| 7 | Flexibility and Efficiency | 1 | 200-run history: no sort/search/filter/bulk/keyboard |
| 8 | Aesthetic and Minimalist Design | 3 | Measured restraint (6 colors, 8 sizes, 3 families). Deduction: priority inversion, empty `<thead>` x3 |
| 9 | Error Recovery | 1 | Worst: 433-char escaped stacktrace behind a "Run internals" details, while Verdict/Elapsed/Worktree all read "—" |
| 10 | Help and Documentation | 1 | No bucket legend, no state glossary, no tooltips, no playbook link |
| **Total** | | **19/40** | **Poor band (47%)** |

Caveat: an ~8/10 design system under a ~4/10 composition. Nearly every lost point is lost in the index arrangement and the failure surface.

## Design Specificity Verdict

Split decision. The run-detail page is unmistakably authored for this product; the index — the actual control room — is a category-default admin table wearing a good palette.

Authored: `stage_stepper` with `:recovering`/`:held` splicing in; three-agent identity block with a live dot on whichever role holds the run; `transcript_chrome` vital signs; two components for one signal chosen by commit state (`run_diff_view` reads git, `edited_files_live` harvests paths from the agent's own tool calls).

Category-default: `<h2>` + paragraph + 10-column table, three times, flat-stacked. Topbar is a `<select>` plus four gray word-pairs. Swap nouns to Orders/Customers/Refunds and nothing structural changes. Nothing in the layout knows runs are concurrent, that they land onto a serialized train, or that the operator's unit of concern is a wave.

Deterministic scan — COVERAGE GAP, not a clean bill: `detect.mjs` returned `[]`/exit 0 on all three invocations but scanned zero files; `.ex`/`.heex` are absent from `SCANNABLE_EXTENSIONS` (detector/node/file-system.mjs:27) and all markup lives in `~H"""` sigils. No diagnostic emitted.

Browser injection ran (overlays since torn down; live server on :8400 stopped, port verified free). Injected detector: `layout-transition — transition: width` (genuine, P3) plus advisory `overused-font — Geist 94%` (FALSE POSITIVE — a single-family system with a mono companion is the design working).

Unsubstantiated report: Assessment B saw the page self-navigate to `/harness/runs/<id>`. `live.ex` has exactly one `push_patch`, inside `handle_event("select_project", …)` — user-triggered. Both assessments shared one browser process and B twice documented the selected-page pointer flipping. Filed as tab contention, not a defect.

## Overall Impression

The detail page is a genuinely good instrument. The index is a status page with an eject button. Biggest opportunity: the failure surface. Harness doctrine says judgment belongs to an agent, yet the one screen aimed at a human is the one place harness refuses to narrate a fact it already witnessed.

## What's Working

1. Stepper + live-dot + transcript-chrome triad — distinguishes "reviewer thinking" from "implementer grinding" without opening anything.
2. Commit-state-aware diff rendering — two components for one signal, chosen by lifecycle position.
3. Confirm copy as token-economy doctrine — the microcopy names whether an action is free.

## Priority Issues

### [P0] The failure explanation is a raw Erlang term
Why: failure triage is the operator's #1 job and the Resume/Escalate/Re-land/Delete choice depends entirely on why it died — currently requires parsing `inspect/1` output in a table cell while Verdict/Elapsed/Worktree render "—" (and the worktree path is inside the hidden string).
Fix: a `run_failure/1` component above the fold — operator-language headline mapped from the reason tuple head (`:review_stuck` → "Reviewer produced no verdict"), one consequence line ("the implementer's commits on `harness/<run-id>` are retained"), the recommended recovery named, raw term behind a disclosure. Index truncates to the headline.
Command: /impeccable clarify

### [P0] The topbar contradicts the rows it summarizes
Verified in source (status_view.ex:150-153): `classify/1` maps `:recovering` AND `:reviewing` to `:repairing`, `:held` to `:in_flight`. Observed live: "1 repairing" over a badge reading "reviewing".
Why: the count strip is the one-glance instrument, and it reports the most common in-flight state (the review gate) as a repair and a paused run as flying.
Fix: split `:reviewing` out; give `:held` its own count; label counts with the same words as the badges; render as `.kpi-stat` tiles with non-zero at full `--text` weight, zeros muted.
Command: /impeccable clarify

### [P1] Priority inversion and no visual hierarchy on the index
`ops_panel` (usually empty) renders above "Active runs". Three co-equal `<h2>`, no `<h1>` in the DOM. Four fleet counts at 12.8px `--text-subtle`, identical at 0 and non-zero. ~40% of a 1440x900 viewport empty while a 433-char stacktrace wraps in a cell.
Fix: reorder Active → History → Ops; add `<h1>`; promote counts to a stat-tile row; collapse empty ops panel; hide empty tables instead of printing a header row for zero rows.
Command: /impeccable layout

### [P1] Recovery actions are missing from the run-detail page
`render_show/1` renders only `kill_button`. The decision is formed on the page with the diff/transcript/criteria/reason, then the operator must navigate back and re-find a 26-char id in a 200-row table.
Fix: render the same `.row-actions` group under Run-info, gated by the identical predicates.
Command: /impeccable shape

### [P1] No responsive strategy at all
Verified: the 1742-line stylesheet has exactly one `@media` block and it is `prefers-reduced-motion`. Browser evidence at narrow viewport: scrollWidth 1189 vs innerWidth 500; `.navbar-links` (641px) and `.page-main` overflow. `.table-scroll` exists and is used by kpi_live.ex:624 and project_explorer.ex:141 but never by `run_table`, so at phone width the Action column is clipped with no horizontal scroll.
Fix: wrap `run_table` in `.table-scroll` now; add a ~900px breakpoint collapsing each run to a card; truncate Detail to one line with a disclosure.
Command: /impeccable adapt

### [P2] Two tokens fail contrast, and both carry interactive meaning
Recomputed and confirmed: `--text-muted` #5c606a on `--bg` #0b0c10 = 3.11:1 (fails AA text) — carries the Delete label, section subheads, footer. `--rule` #2a2e38 = 1.44:1 (fails 3:1 non-text) and is the only boundary on the project `<select>`, both topbar link-buttons, Delete, and every row rule.
Fix: lift `--text-muted` to >= #6f737d; add `--rule-strong` >= #3a3f4b for interactive borders; keep #2a2e38 as `--rule-soft` for decoration.
Command: /impeccable audit

## Cognitive Load: 6 of 8 fail — high (critical)

Failing: single focus, chunking, grouping, visual hierarchy, minimal choices, working memory. Passing: one-thing-at-a-time. Partial: progressive disclosure — the wrong thing is hidden (failure reason), the right thing isn't (transcript fully expanded; 11,990px page height, 149 `<details>`, 41 `<pre>`).
Over-limit decision points: 9 nav links with no current-state; 7 topbar controls; 20-option unsorted project select; 10 columns per row; up to 5 same-shaped action buttons on a failed row.

## Emotional Journey

Peak: "Changed files 7 · +478 −19" with per-file status letters, stat bars and branch name.
Both endings bad: index ends on an empty `<thead>` under "No unmerged runs" (x3 per page); detail ends after ~11,000px of raw transcript.
Valley — empty dashboard: two flat sentences, three empty table headers, four zeros, a 19-project dropdown, and no way to dispatch from here (dispatch lives on Settings).
Silent valley: no `.phx-error` / `.phx-disconnected` styling anywhere. A dropped LiveSocket is pixel-identical to a live one.

## Persona Red Flags

Alex (power user): no sort/search/filter/bulk on 200 rows; 20 unsorted projects, no type-ahead; NO focus styling on any control-room control (rings authored for .toggle/.btn-dispatch/.btn-save/.compare-lane-head/.catalog-model-toggle only — confirmed live that a dashboard button falls back to Chrome's UA ring); no keyboard shortcuts; every tab titled "Harness Dashboard"; `Tokens 6555778` with no separators or cost; `current_activity_label/1` isn't liveness-gated, so a settled failed run advertises "running git add AGENTS.md" in present tense.

Sam (keyboard + screen reader): both run tables have 20 `<th>` with zero `scope="col"` and no `<caption>` — every cell announced without a column name; `operator_flash` renders `role="status" aria-live="polite"` only when a notice exists (measured `[aria-live]` count = 0 on a quiet page), so operator notices are silent; project `<select>` has no label/aria-label; no `<h1>`; `.cf-live-dot` is aria-hidden with meaning carried by color alone; "Resume"/"Escalate"/"Delete" repeated across 200 rows with names that never say what they act on; 16 of 17 interactive elements under 44x44px (nav links ~28px tall).

The orchestrator (derived from repo CLAUDE.md): CLAUDE.md states the primary user is an AI agent, yet this surface is built entirely for a human, and dispatch/hold/steer exist only over MCP. The dashboard shows `verdict` but not `concerns`, `checks`, `ratings` or `proposed_tasks`.

## Minor Observations

- `landed_label/2` ignores `summaries`; `landed_entry?/2` ignores its 2nd arg, called as `landed_entry?(&1, %{})`.
- `landed_toggle_label/2` recomputes a full filter + count over up to 200 entries every index render.
- `✓ 4f2a91b` unlinked, not selectable as a unit; the ✓ is redundant with the sha's presence.
- Footer's visual-stop position spent on a tagline where connection state / last-updated belongs.
- `--page-max-width: 1240px` caps a 10-column table on a 1440+ monitor.
- Two overlapping nav systems; neither complete; topbar uses `<a href>` full page loads.
- `navbar/1`'s @doc says active-state was "deliberately omitted" but tokens.ex ships the `[data-active]` rule — dead CSS + stale rationale.
- `transition: width` on a body-level rule — animate `transform` instead.

## Questions to Consider

1. What would this page look like if the primary object were the wave, not the run?
2. Why is the one surface aimed at a human the one place harness refuses to let an agent narrate the fact it already witnessed?
3. Would `onchain#91 · cursor→grok · 4m` be the better primary key, with the run id demoted to a copy affordance?
4. What would the run row look like if `concerns: 3` were a column?
5. Control room, or status page with an eject button?
