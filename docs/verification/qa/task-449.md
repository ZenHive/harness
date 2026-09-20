# Task 449 — QA dashboard verification

The QA navigation item opens `/harness/qa`; project drill-downs use
`/harness/qa/:name`. The surface reuses the dashboard's Insights components and
tokens. Start/retry inserts `Harness.Audit.Worker` jobs; it does not execute checks
in the LiveView or change project settings.

## Acceptance coverage

- Registered-project overview, project/status filters, loading/empty/error states,
  queued/running jobs and latest revision/time facts.
- Ten-attempt history with exact command, target/range, agent/model, and on-demand
  agent-authored report/check detail. Missing per-check outcomes are unavailable.
  Raw evidence is paged in 8,000-character slices at the database boundary.
- Queue acknowledgement and errors; concurrent submissions on independent
  Postgres connections; reuse of waiting audits and matching running attempts;
  retention of newer revision/command requests; unchanged-revision rechecks.
- Effective and persisted registration settings, landing overrides, catalog-based
  focused-dispatch adoption, retained commands, and command/revision drift.
  Local remote-tracking revisions are explicitly **last fetched**, not a claim
  about the current remote tip. Enqueue resolves the remote target.
- Ten-second summary refresh; transcripts and report details are not polled.
  Settings command editing remains available from the page.
- LiveView, isolated Postgres/Oban, and desktop/mobile browser checks. No fleet
  activation, production job execution, service restart or deployment gate.

## Focused checks

Use a disposable database. Clear inherited database URLs so the explicit test
database name takes effect:

```sh
export MIX_ENV=test HARNESS_DB_NAME=harness_qa449_review
unset DATABASE_URL HARNESS_DATABASE_URL
mix ecto.create
mix ecto.migrate
mix test test/harness/dashboard/qa_live_test.exs test/harness/audit/qa_test.exs --include integration
```

Implementation run: **26 tests passed**. The existing SettingsLive suite also
passed its 62 tests in the focused integration-boundary run. Formatting,
compilation with warnings as errors, and `git diff --check` are separate scoped
checks. Full suites, coverage and analyzers belong to post-merge QA.

## Browser check

```sh
npm install --prefix .harness/browser playwright
node test/browser/qa.mjs
```

A Playwright Chromium installation is required. The runner creates its own
`harness_qa_browser_<pid>` database and disposable Git origin, migrates only that
database, and starts a test-only loopback server on port 44049
(`QA_BROWSER_PORT` overrides it). Oban runs in manual test mode with queues off.
The runner waits for its child server's readiness marker and fails on a port
conflict. Cleanup stops its process tree and removes its database and fixtures.

Implementation run: **passed at 1440px and 390px** with no horizontal overflow or
browser errors. Checks exercise project/status filtering, empty results, filter
Tab order, evidence access by Enter, and queue/duplicate acknowledgement.
Screenshots, measurements and server output are written to `.harness/qa-browser/`.
The independent UI reviewer returned **ship**, scoped to the supplied extension
brief and existing dashboard styles; harness's delivery reviewer remains the gate.
