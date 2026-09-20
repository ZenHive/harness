# Run Insights verification — Task 443

Historical delivery record. [Task 445 corrections and verification](task-445/README.md)
describe current agent support, retrieval, lifecycle behavior and rendered UI.

The feature is disabled by default. No operator server, production database,
installed skill or production observer configuration was changed.

## Execution boundary and live evidence

The installed Claude CLI's own help documents `--tools ""`, `--safe-mode`,
`--strict-mcp-config`, empty MCP configuration, disabled slash commands, disabled
hooks and disabled session persistence. The witness uses these controls, not the
coding adapters' autonomous permission modes. Claude is the only selectable
observer agent; model selection is explicit. Provider output is finding data,
never commands or lifecycle artifacts.

`WitnessLiveTest` was written and executed before introducing the witness double.
It checks the real CLI initialization event's empty tool list, absence of tool-use
events, an attempted write remaining absent, and a real invalid-model failure.
The observer's own claim about available tools was inconsistent and is not the
security oracle. Live output also established that JSON can arrive inside a JSON
Markdown fence; that wrapper is accepted, while malformed structures and invented
citations are rejected.

- [Live witness evidence](live-witness.json): actual Claude responses to controlled
  completed/active run excerpts across two projects, followed by a later pass
  receiving previous findings. The later pass revised the existing finding.
- [Live Postgres evidence](live-postgres.json): actual observation passes through
  `Harness.Insights.observe/1`, collecting two registered projects' stored run
  records, publishing to Postgres, then revising after a late cold-check update.
  Includes retained sources and chronological revisions.

These are controlled test records, **not production-run findings**. The active
registry/status/transcript path is separately exercised using an actual supervised
run with the repository's test adapter. An independent reviewer must assess the
claims against the quoted inputs; the observer's prose is not a verdict.

## Checks performed in the assigned worktree

| Check | Observed result |
| --- | --- |
| Baseline `mix test.json --cover --quiet --output /tmp/run-insights-cov.json` | Passed; 2,402 passing tests, 97 excluded; three tests passed automatic retries |
| Existing-module coverage before mutation | Components 93.85%, Live 86.09%, SettingsLive 86.64%, Manifest 91.23%, ResultStore.Memory 100% |
| Isolated Postgres Oban coverage tests | Raised Oban from 54.12% to 80% before editing; 58 passing, one automatic retry |
| Live CLI boundary and two-pass witness tests | 2 passed |
| Postgres context suite including real witness | 5 passed |
| Separate database-session advisory lock test | 1 passed |
| Repo restart plus context tests | 8 passed |
| Context, publication, Postgres and LiveView tests | 18 passed without retries |
| Final memory-store, context, publication and LiveView tests | 40 passed without retries |
| Impeccable mechanical UI detector | No findings |
| `git diff --check` | Passed |
| Final `mix check.dispatch` | Passed (format, compile, Credo, Doctor, Sobelow) |

The broader dashboard/Oban run had 579 passing tests and one new active-run test
fixture failure, counted four times by automatic retries. The fixture omitted a
RunFeed subscription; cleanup also needed to await run termination. Both were
corrected and the focused tests rerun without retries. The final `mix check.dispatch` passed.

[Coverage evidence](baseline-coverage.json) preserves the pre-mutation measurements.
The router is excluded by the repository's existing coverage configuration.

## Reproduce with an isolated database

```sh
createdb harness_insights_test
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_insights_test MIX_ENV=test mix ecto.migrate
claude auth login
# API-key alternative: export ANTHROPIC_API_KEY='your-key'
# Obtain the key at https://console.anthropic.com/settings/keys.
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_insights_test MIX_ENV=test mix test test/harness/insights test/harness/dashboard/insights_live_test.exs --include integration
mix check.dispatch
dropdb harness_insights_test
```

The restart test commits observation documents, stops and restarts only the
worktree's Repo process, checks retained progress/history, then deletes its test
rows. No PostgreSQL server restart is involved.

## Delivered surfaces and limits

- Persistent pass/finding/revision documents, retained excerpts and source links;
  atomic publication plus progress, idempotent delivery and a cross-session lock.
- Seven-day bootstrap anchor and bounded cyclic scans, including late landing and
  audit changes. Fingerprints skip unchanged snapshots; incomplete pages and
  unavailable/truncated sources are explicit. Prior findings are supplied in
  bounded pages with explicitly shortened context.
- Independent settings, hourly default and selectable cadence, a dedicated Oban
  queue and manual enqueue. Backlog pages continue on subsequent minute ticks.
- MAIN NAVBAR, `/harness/insights`, project filtering before pagination,
  `/harness/insights/:id`, live status/settings updates and related-run links.
- Bounded Elixir/MCP status, observation, findings and history operations; the
  canonical harness-driver skill is updated.
- With `repo_enabled: false`, storage and direct `observe/1` are ephemeral. Oban
  scheduling/manual enqueue requires Postgres and the UI states this explicitly.

The reviewer owns approval. The orchestrator owns `mix precommit.full` on the
integrated base, installed-skill propagation and production activation.
