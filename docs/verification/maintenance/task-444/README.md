# Task 444 verification

Implementation evidence recorded on 2026-09-20. The independent harness reviewer remains the approval gate; these are implementer-run checks, not independent approval.

## Results

- `mix check.dispatch`: exit 0; full output in [check-dispatch.log](check-dispatch.log).
- Focused maintenance and LiveView tests, including Postgres integration: **27 passed, 0 failed**; two live-agent tests excluded from this invocation and run separately. See [focused-tests.json](focused-tests.json).
- Actual configured Codex agent, pinned `gpt-6-astra`: **2 passed, 0 failed** in 253 seconds. The tests cover real discovery/publication/replay and a real unavailable-model failure without fallback. See [live-tests.json](live-tests.json).
- [Retained live assessment](live-assessment.json): disposable repository source revision, explicit agent/model, provider-owned citations, executable task criteria, numeric task id and stable publication identity. The live assessment justifies one dependency task incorporating public security evidence. It explicitly declines unsupported performance, test-speed and refactor tasks. Private advisories, freshness snapshots and suite-health evidence were unavailable, so the result is `partial_evidence`, not a clean result. The reviewer must independently check the citations and criteria; the model's assessment is not itself verification of the upgrade.
- Browser checks cover fleet, repository and finding routes at 1440px and 390px, settings submission, keyboard navigation, page errors and horizontal overflow. [browser.json](browser.json) records no errors or overflow. The runner used its own memory-only fixture server on loopback port 44044 and stopped its process tree. A subsequent scoped `box-sizing` correction prevents settings input padding from extending beyond its panel.
- Pre-mutation coverage: Components 93.89%, Manifest 91.23%, Oban raised to 86.81% before mutation. [baseline.json](baseline.json) retains the coverage and four pre-existing full-suite contract failures. Those failures concern Dispatch API/manifest contract expectations; they were not repaired by this feature. Full integrated QA belongs to Task 447/orchestrator.

## Focused reproduction

Use an owned disposable database. The inherited URL overrides the database-name setting, so remove both URL variables:

```sh
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_maintenance_test MIX_ENV=test mix ecto.create
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_maintenance_test MIX_ENV=test mix ecto.migrate
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_maintenance_test mix test.json test/harness/maintenance test/harness/dashboard/maintenance_live_test.exs --include integration --quiet --output /tmp/maintenance-focused.json
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_maintenance_test HARNESS_MAINTENANCE_TEST_MODEL=gpt-6-astra HARNESS_MAINTENANCE_EVIDENCE=/tmp/maintenance-assessment.json MIX_ENV=test mix test.json test/harness/maintenance/live_test.exs --include live_agent --quiet --output /tmp/maintenance-live.json
env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_maintenance_test mix check.dispatch
node test/browser/maintenance.mjs
```

Live tests require an authenticated `codex login` and an available explicitly selected model. Missing credentials fail with setup instructions. Browser setup and operation controls are documented in the canonical [harness driver](../../../../skills/harness-driver/SKILL.md#repository-maintenance).

## Acceptance coverage and boundaries

The implementation includes per-repository opt-in/pinned settings, a weekly default, bounded serialized scheduling, Postgres persistence, visibly ephemeral database-free mode, isolated current-target analysis, retained assessments and findings, and durable roadmap publication through the existing writer. Mechanical tests cover concurrent triggers, fleet locks, restart, interrupted publication, committed-result checkpoint recovery, retry identities, missing/deleted roadmap history, concurrent remote changes, empty roadmaps, the three-task cap including running coalesced work, unavailable evidence, blocked consumer coordination and LiveView controls/history. Migration scope and comparable-measurement requirements are passed to the AI and retained in generated criteria; they are not replaced with keyword-based judgment.

Maintenance has separate navigation and bounded Elixir/MCP operations. Analysis is shell-disabled and uses bounded tracked-file retrieval; it cannot implement code. A separate tool-free disclosure assessment sanitizes proposed public content before persistence. Raw private advisory responses and command output are transient and do not enter dashboard records. Existing dispatch/review/landing policies remain authoritative. Landing is never automatically labeled verified improvement. Only Codex is supported as the read-only analyst; task routing is validated against the live routing roster.

Operational correction: an initial database-create command inherited the runtime URL despite a disposable database-name setting; it reported the existing database. The new migration was not applied there. Existing integration tests were also initially run through that inherited URL using SQL Sandbox transactions. This was disclosed during implementation and corrected by removing the URL variables. All subsequent maintenance database integration used the owned `harness_maintenance_da2364ed` database. No production maintenance was enabled, no production server was restarted, and no operator checkout was modified by a sweep. Installed-skill propagation, production activation and fleet rollout remain with the orchestrator/Task 448.
