# Task 478 dependency update — 2026-10-31

## Inventory and registry evidence

- Root `mix.exs` / `mix.lock`: 92 Hex packages. Refreshed with `mix hex.outdated --all`, `mix deps.update --all`, and live `https://hex.pm/api/packages/<package>` metadata. All resolved packages remain registry dependencies.
- `.mcp.json`: Chrome DevTools MCP, launched by `npx`, updated from **1.7.0 to 1.12.0**, the npm `latest` release. Source: https://registry.npmjs.org/chrome-devtools-mcp/latest.
- `.cursor/mcp.json`: HTTP endpoints only; no package pins.
- Browser verification installs unpinned Playwright under ignored `.harness/browser`; it is not a shipped dependency.
- No application npm, Python, Go, or Rust manifest/lock. Phoenix and LiveView JS are served from their Hex packages by the dashboard endpoint. Geist font URLs use `geist@latest`, not a version pin.
- `priv/templates/in_repo_harness/mix.exs`: bootstrap template, not a separate installed application; its Harness, Tidewave and Bandit ranges already admit the current compatible versions. No lockfile.
- `test/support/fixtures/elixir_project/mix.exs`: Jason fixture; its `~> 1.4` permits current 1.4.5.
- `test/support/fixtures/rust_project/Cargo.toml` / `Cargo.lock`: intentionally outdated Serde 1.0.0, asserted by `test/harness/dep_freshness/integration_test.exs`; retained as test input. The failing Rust fixture has no dependencies.
- `test/fixtures/flutter_app/pubspec.yaml`: Flutter SDK dependencies only, no separately versioned libraries. `.tool-versions` pins toolchains, not libraries; unchanged. Agent model pins unchanged.

Raw registry responses, upstream packaged changelogs, before/after scans, solver output and commands are retained under `.harness/evidence/dependency-update/` for reviewer inspection (excluded from delivery commits).

## Applied Hex updates

| Package | Before | After |
|---|---|---|
| anubis_mcp | 2.0.0 | 2.2.0 |
| bandit | 1.12.5 | 1.14.1 |
| castore | 1.0.21 | 1.0.22 |
| decimal | 3.1.1 | 3.2.0 |
| elixir_make | 0.10.0 | 0.10.1 |
| finch | 0.23.0 | 0.24.0 |
| floki | 0.38.4 | 0.38.5 |
| hex_solver | 0.3.0 | 0.3.2 |
| hpax | 1.0.4 | 1.1.0 |
| lazy_html | 0.1.12 | 0.1.13 |
| makeup | 1.2.2 | 1.2.3 |
| mint | 1.10.1 | 1.11.0 |
| oban | 2.24.1 | 2.24.2 |
| oban_met | 1.3.1 | 1.3.3 |
| oban_web | 2.13.0 | 2.13.1 |
| peri | 0.9.0 | 0.11.3 |
| phoenix | 1.8.14 | 1.8.16 |
| phoenix_html | 4.3.0 | 4.4.0 |
| phoenix_live_view | 1.2.12 | 1.2.13 |
| phoenix_pubsub | 2.3.0 | 2.4.1 |
| plug_crypto | 2.2.0 | 2.2.1 |
| req | 0.7.4 | 0.7.5 |
| rustler_precompiled | 0.9.0 | 0.10.1 |
| sobelow | 0.15.0 | 0.18.1 |
| sourceror | 1.12.3 | 1.13.0 |
| spitfire | 0.4.2 | 0.4.3 |
| thousand_island | 1.5.0 | 1.6.0 |
| tidewave | 0.9.1 | 0.9.2 |
| tzdata | 1.2.1 | 1.2.2 |
| websock_adapter | 0.6.0 | 0.7.0 |

Thirty packages updated in one resolution. Direct dependency minimums were raised to the selected minor series where appropriate. No overrides, dependency removals, git/path substitutes, or product features were introduced.

## Remaining outdated packages — upstream constraints

| Package | Retained | Latest stable | Published blocker |
|---|---|---|---|
| ex_ast | 0.12.10 | 0.16.0 | Reach 2.8.4 requires `~> 0.12.0`; Exograph 0.9.12 requires `~> 0.12.9` |
| igniter | 0.8.4 | 0.8.5 | 0.8.5 requires ExAST `~> 0.16`, conflicting with Reach/Exograph |
| volt | 0.14.12 | 0.23.0 | Exograph requires `~> 0.14.2` |
| quackdb | 0.5.22 | 0.7.0 | Exograph requires `~> 0.5.13` |
| muontrap | 1.8.0 | 2.0.1 | QuackDB 0.5.22 requires `~> 1.5`; explicit root `~> 2.0` solver attempt failed |
| json_codec | 0.1.6 | 0.3.1 | Exograph requires `~> 0.1.1`; retained Volt requires `~> 0.1.5` |
| oxc | 0.17.8 | 0.19.0 | Retained Volt requires `~> 0.17.1`; QuickBEAM requires `~> 0.17.2` |
| quickbeam | 0.10.20 | 0.11.3 | Retained Volt requires `~> 0.10.18` |
| vize | 0.13.1 | 0.17.2 | Retained Volt requires `~> 0.13.0` |

These need compatible published Exograph and Reach releases. `mix hex.outdated igniter` labels the update possible because root consumers accept 0.8.5; its own new ExAST requirement makes the combined graph incompatible. Evidence: `igniter/new-mix.exs`, each `<package>-constraints.txt`, and `solver-latest-muontrap.txt`.

## Compatibility review

Reviewed upstream changelogs from published Hex tarballs before resolution. Important boundaries:

- [Anubis 2.2](https://github.com/zoedsoupe/anubis-mcp/blob/v2.2.0/CHANGELOG.md) enables stateless MCP alongside the legacy protocol. Added request-level regression tests for stateless tool discovery and rejection of missing protocol metadata; retained legacy initialization and long-running/concurrent tool tests.
- [MuonTrap 2](https://github.com/fhunleth/muontrap/blob/v2.0.1/CHANGELOG.md) changes cgroup support; Harness uses ordinary subprocess commands, but the graph blocks the update independently of API compatibility.
- [ExAST](https://hex.pm/packages/ex_ast/0.16.0) changes matching semantics; [Volt](https://hex.pm/packages/volt/0.23.0) changes formatting, lint diagnostics and native dependencies. Their upstream constraints were respected.
- Phoenix updates its shipped JS connection handling; LiveView, HTML and PubSub were exercised through LiveView tests and a real browser/WebSocket flow. Bandit/ThousandIsland and Finch/Mint updated together.
- Oban's patch preserves execution metadata on snooze; isolated live PostgreSQL tests exercised dispatch, uniqueness, rescue and tracked landing branches.
- Castore has no packaged changelog or GitHub release at `v1.0.22`; metadata and package diff remain the evidence. Spitfire's missing packaged changelog was supplemented with its GitHub release notes.

## Verification

All paths below are relative to `.harness/evidence/dependency-update/`.

| Command | Result / evidence |
|---|---|
| `mix deps.update --all` | Passed; `update.txt` |
| `mix compile --warnings-as-errors` | Exit 0; `compile.txt`. Dependency compilation still emits existing Exograph undefined-Hex API and xref-deprecation warnings; this is not a claim of warning-free dependencies. |
| `mix format --check-formatted mix.exs test/harness/dashboard/mcp_server_test.exs` | Passed; `format-final.txt` |
| `mix harness.deps.check` | Passed; `constraint-check.txt` |
| Focused test command below | 724/725 passed, 29 excluded; the only failure was the newly written stateless request missing required `_meta`. Corrected test request; `tests.txt`. |
| `MIX_ENV=test mix test test/harness/dashboard/mcp_server_test.exs:288 test/harness/dashboard/mcp_server_test.exs:319` | Both final stateless regression tests passed; `mcp-regression.txt`. |
| `bash .harness/evidence/dependency-update/postgres-check.sh` | 13 integration tests passed, 51 unrelated tests excluded; `pg-tests.txt`, `pg-migrate.txt`, `pg-stop.txt`. Private PostgreSQL 18 cluster on port 44786, stopped on exit; owned database files removed after verification. |
| `INSIGHTS_BROWSER_PORT=44785 node .harness/evidence/dependency-update/browser.mjs` | Passed desktop/mobile settings save, navigation, PubSub updates and keyboard interaction; `browser/browser.json`, 14 screenshots. Inspected `desktop-populated.png` and `mobile-settings.png`: content legible, controls visible, no horizontal clipping. |
| `npx --yes chrome-devtools-mcp@1.12.0 --isolated --help` | Passed; `chrome-help.txt` |
| `python3 .harness/evidence/dependency-update/chrome-smoke.py` | Real stdio MCP initialize and tools/list passed; `chrome-smoke.json` |
| `mix help sobelow`, `mix help ex_ast.search`, `mix help volt.js.check` | Tool entry points loaded; corresponding `*-help.txt`. These are smoke checks, not full analyzer runs. |
| `mix hex.audit` | No retired/security-advisory packages reported; `hex-audit.txt`. Two global ignored advisory IDs were reported unmatched. No suppression added. |
| `git diff --check` | Passed |

Focused test command:

```sh
MIX_ENV=test mix test test/harness/dashboard \
  test/harness/maintenance/command_test.exs \
  test/harness/insights/codex_witness_test.exs \
  test/harness/code_search_test.exs test/harness/agent_driver_test.exs \
  test/harness/mix_project_test.exs test/harness/dep_freshness \
  test/harness/tooling_baseline test/mix/tasks/harness_deps_check_test.exs \
  test/harness/oban_dispatch_test.exs test/harness/oban_lifeline_test.exs \
  test/harness/oban_queue_bootstrap_test.exs test/harness/oban_tracked_branches_test.exs
```

PostgreSQL integration selection was those four Oban files with `--only integration`. Setup attempts exposed an overlong Unix socket path, SQL_ASCII template encoding, and a mistaken `mix ecto.create ecto.migrate` invocation that ran only creation. Corrected to TCP-only private PostgreSQL, a UTF8 database from template0, and explicit `mix ecto.migrate`; the unmigrated failure log is retained as `pg-tests-unmigrated.txt`.

The browser runner is an evidence-local copy of `test/browser/run_insights.mjs`, with output redirected into evidence and its readiness selector narrowed from `.phx-connected` to `[data-phx-main].phx-connected`. The original selector matched both the inbox badge and main LiveView and failed strict mode. `browser.txt` retains that failure; `browser-retry.txt` and `browser/browser.json` record the corrected run. No operator server was used or restarted.

Full-project tests, coverage and full analyzers were not run under the focused-verification policy. Live-agent/provider tests were excluded. `mix_audit` and `osv-scanner` are not installed; no comprehensive supply-chain audit is claimed. The cross-family reviewer remains the acceptance gate.
