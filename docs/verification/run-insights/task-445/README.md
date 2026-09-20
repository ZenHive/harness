# Task 445 — Run Insights correction

This is the correction record. Task 443 and the adjacent architect audit remain
unchanged. No operator server, production settings or installed skill was changed.
The browser server and Postgres database used isolated test fixtures.

## Delivered behavior

- The maintained `InsightsEvidenceContract` runs the three architect probes
  against memory and Postgres, plus UTF-8 continuations, structured check/reason
  changes, and changes beyond excerpts. Historical evidence includes all retained
  run fields. SQL and `inspect/2` no longer silently shorten provider facts.
- Initial finding pages contain 20 complete findings. The AI can request older
  pages and 8,000-byte source continuations. Previously read material remains in
  its context. Full-content hashes identify changed snapshots; successful
  publication alone consumes them. Retrieval has no relevance filter or ranking.
  Exhausting 32 reads or the 180-second consultation deadline fails the pass.
- Pass ownership records the process, node and a VM-scoped UUID incarnation. Status/tick
  reconciliation rechecks abandoned passes under the observation lock before
  marking them interrupted. Exceptions, throws, worker death, consultation timeout
  and final database-write rejection preserve the successful checkpoint.
  Scheduling uses a separate attempt timestamp, so Daily still applies after an
  Oban retry group is discarded.
- Unconfigured settings use the Codex standing model, with observation paused.
  Explicit selections survive default changes. Missing, disabled, blocked or
  unavailable agent/model choices fail visibly; there is no provider fallback.
  The settings panel uses the enabled-agent and selected-model catalogs.
- Overview, settings and history retain the existing dark dashboard and navbar.
  Fields stack on mobile; actions use dashboard button styles. Paused and filtered
  empty states have configuration/clear actions. History separates the current
  assessment from chronological revisions and keyboard-operable excerpts.

## Owning adapter and live evidence

The new `Harness.AgentAdapter.Codex.Observer.command/3` belongs to the adapter
package, not a bypass in Harness. Its pushed revision is
[`76cc3d655cfe7feac2a6ecb8377dbcbaee5f6318`](https://github.com/ZenHive/harness_agent_adapter/commit/76cc3d655cfe7feac2a6ecb8377dbcbaee5f6318),
pinned in `mix.exs` and `mix.lock` (branch `task-445-codex-observer`).

The [official noninteractive CLI contract](https://learn.chatgpt.com/docs/non-interactive-mode)
and installed `codex exec --help` establish the explicit sandbox, configuration
isolation, ephemeral session, JSON event stream and output-schema options.
Codex is **read-only, not described as tool-free**. Shell, hooks, web search and
MCP are disabled; no lifecycle tools are supplied. Claude remains an explicit
choice with its own tool-free invocation. Schemas constrain structure, never
semantic relevance or finding correctness.

- [Codex boundary](codex-boundary.json): CLI 0.155.0, exact argv, explicit
  `gpt-6-astra`, real rejected `harness-insights-invalid-model`, and an attempted
  file-creation prompt. The fixture directory contents remained identical and
  its marker was absent. These filesystem assertions are independent of the
  observer's explanation. The standalone `codex sandbox linux --help` helper
  failed with a local bubblewrap loopback permission error; that helper is not
  the tested `codex exec` invocation and is not claimed successful.
- [Codex Postgres observations](codex-postgres.json): actual observations through
  `Insights.observe/1`, two registered fixture projects, persisted findings and
  revisions, and later cold-check evidence revising the original finding.
- [Claude witness](claude-witness.json): real cross-project completed/active
  evidence, cited findings, and a later revision under the explicit Claude path.

These are synthetic test run records evaluated by real providers. Recordings
preserve what happened; they are not a substitute for rerunning the live tests.

## Rendered inspection

The implementer inspected the actual Chromium-rendered screenshots at 1440×1000
and 390×844. Concrete observations:

- Desktop overview has a compact action header, a four-field observation summary
  and a separate project toolbar. Paused onboarding identifies the settings action.
- Desktop settings use a two-column panel with labels above controls; mobile
  settings become one column without clipped labels or horizontal scrolling.
- Populated rows give explanation and assessment visual priority. Dates, project
  and observer metadata remain secondary.
- History has a distinct current-assessment panel, followed by two chronological
  revisions. Long evidence wraps inside expandable excerpts. Enter expands a
  focused summary; Tab advances through the labelled settings controls.
- Provider failures are visible in the summary. Filtered-empty views offer a
  working clear action. Browser checks found no horizontal overflow or page errors.

| Surface | Desktop | Mobile |
| --- | --- | --- |
| Paused overview | [Image](desktop-paused.png) | [Image](mobile-paused.png) |
| Settings | [Image](desktop-settings.png) | [Image](mobile-settings.png) |
| Filtered empty | [Image](desktop-filtered-empty.png) | [Image](mobile-filtered-empty.png) |
| Populated overview | [Image](desktop-populated.png) | [Image](mobile-populated.png) |
| History | [Image](desktop-history.png) | [Image](mobile-history.png) |
| Expanded evidence | [Image](desktop-excerpt.png) | [Image](mobile-excerpt.png) |
| Provider error | [Image](desktop-error.png) | [Image](mobile-error.png) |

[Browser measurements](browser.json) record the viewport/overflow checks and
keyboard interactions. The isolated runner also passed a SIGTERM cancellation
probe: exit 143, with its owned server port released. It never reuses a server.
The reviewer must independently render and inspect these surfaces; this document
records implementer inspection, not reviewer approval.

## Verification results

[Check summaries and coverage](checks.json) preserve the measurements.

- Architect probes before changes: **3 failed**.
- Focused memory/Postgres/LiveView/adapter suite, including real Codex and Claude:
  **52 passed**, no retries, exclusions or skips.
- Final retrieval/termination supplemental suite: **21 passed**, including two
  actual fresh-VM identity probes. Attempt coverage is **96.15%** and Consultation
  coverage is **100%**. Main focused coverage: Insights **95.56%**,
  Evidence **92.68%**, CodexWitness **96.15%**, Selection **100%**, Witness **100%**,
  Store **95.12%**, LiveView **92.31%**. The stylesheet's render function is covered;
  its generated module-declaration line reports 50%, without a coverage exclusion.
- Full offline suite: **2,443 passed, 2 failed, 110 integration tests excluded**.
  Both failures were in untouched `dashboard/live_mount_test.exs` (fleet idle
  state and held/running badge). The one isolated file rerun passed all **25 tests**; the original
  integrated failure remains reported.
- `mix check.dispatch`: **passed**, including format, warning-free project
  compilation, Credo, Doctor and Sobelow. Sobelow emits its existing router-location
  warning; that does not establish a full security review.
- Impeccable detector: no findings. `git diff --check`: passed.

An earlier real Claude revision failed citation validation; the final focused live
suite passed with the clarified common prompt. An initial Codex response was
malformed; the verified CLI output-schema contract now supplies structural output
constraints. An initial standalone boundary test waited on inherited stdin and
failed its timeout; it now closes stdin explicitly and passes. No test was skipped
or made to accept these failures.

The initial full gate stopped at Descripex's `~> 1.0.0` policy violation. Because
`mix.exs` was touched for the adapter pin, the repository's touched-file rule
required fixing it: the constraint is now `~> 1.0`, with the locked version
unchanged. The final `mix precommit.full` still failed in its test stage:
**2,443 passed, 2 failed, 110 excluded**, with **84.16%** overall coverage (the
80% threshold passed). Its summary-only output does not identify the failed test
names. Later clone, architecture and Dialyzer stages did not run. This gate is
**not green**; see [the durable gate summary](full-gate.json).

## Reproduce

Authenticate the intended providers with `codex login` and `claude auth login`.
API-key alternatives are `export OPENAI_API_KEY='your-key'` from
https://platform.openai.com/api-keys and `export ANTHROPIC_API_KEY='your-key'` from
https://console.anthropic.com/settings/keys. Missing CLIs or provider access fail
the live tests loudly.

```sh
mix deps.get
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_insights_445 MIX_ENV=test mix ecto.create
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_insights_445 MIX_ENV=test mix ecto.migrate --migrations-path priv/repo/migrations
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_insights_445 MIX_ENV=test mix test.json test/harness/insights test/harness/dashboard/insights_live_test.exs --include integration --cover --quiet --no-retry --output /tmp/insights-445.json
npm install --prefix .harness/browser playwright
node test/browser/run_insights.mjs
mix check.dispatch
mix precommit.full
dropdb harness_insights_445
```

The browser command starts only a test-mode server with memory fixtures, no
scheduler and no database. Its loopback port defaults to 44045 and can be set with
`INSIGHTS_BROWSER_PORT`; conflicts fail. Production activation, deployment,
installed-skill propagation and the independent review verdict remain with the
orchestrator/reviewer.
