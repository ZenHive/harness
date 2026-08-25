# Dependency Audit — harness

Date: 2026-08-25. Sources: `mix.exs`, `mix.lock`, `mix hex.audit`, hex.pm API (used directly because `mix hex.outdated` crashes — see Tooling note).

## Findings

### [MEDIUM] `req` is a declared runtime dep with zero call sites
`{:req, "~> 0.5"}` (locked 0.7.3) has no `Req.` usage anywhere in `lib/`, `config/`, or the `harness_agent_adapter` git dep; the only `:req` mentions are fixture data in `test/harness/dep_freshness/row_test.exs` and `test/harness/tooling_baseline/mix_project_reader_test.exs`. It drags finch/mint/nimble_pool into the runtime application tree for nothing. `igniter` (dev/test) declares its own `req` dependency, so removing the top-level entry does not break dev tooling. Recommend: drop from `deps/0` (or move behind the dev/test tools if it exists only to seed the lock).

### [MEDIUM] `anubis_mcp` 2.0.0 is LGPL-3.0 — the only non-permissive license in the runtime tree
Everything else (direct + transitive runtime) is MIT/Apache-2.0. LGPL-3.0 on a BEAM dependency is a gray zone (no C-style dynamic-linking boundary); for a public MIT-style repo this is usually tolerable but is a real obligation if harness is ever distributed as a compiled release to third parties. Worth a conscious sign-off, not a code change.

### [MEDIUM] `harness_agent_adapter` git dep carries no `ref:`/`tag:` in mix.exs
`mix.lock` pins SHA `d869805c0dd1f16625d6a83cec408585250f643b` (currently == remote HEAD, single "initial" extraction commit), so builds are reproducible **as long as the lock is respected**. But any `mix deps.update harness_agent_adapter` silently tracks whatever HEAD is, and there is no tagged release to diff against. Recommend: tag releases in the adapter repo and pin `tag:` (or at least `ref:`) once it stabilizes. Also note: a git dep is invisible to `mix hex.audit` retirement checks.

### [LOW] Constraint-blocked dev-tool bumps (no action forced)
- `ex_ast` locked 0.12.10, latest 0.13.1 — blocked by mix.exs `~> 0.12` **and** transitively by `reach ~> 0.12.0` / `exograph ~> 0.12.9`; upstream releases must move first.
- `volt` locked 0.14.12, latest 0.17.10 — mix.exs `~> 0.11` would allow it, but `exograph`'s `volt ~> 0.14.2` (optional, activated) blocks the bump.
Both are dev/test-only (`runtime: false`); no security exposure.

### [LOW] Tooling: `mix hex.outdated` crashes on registry fetch timeouts
Hex 2.4.2 `MatchError` in `Mix.Tasks.Hex.Outdated.latest_version/4` when registry record fetches time out (reproduced 3×, cached records insufficient). Not a repo defect; audited via the hex.pm HTTP API instead. If it persists across networks, worth a `HEX_HTTP_TIMEOUT` bump or a hex upgrade.

## Clean areas (one line each)
- **Vulnerabilities:** `mix hex.audit` — no retired packages; **no `gun`/`cowlib` in mix.lock** (anubis_mcp's gun dep is optional and not pulled — the adjudicated EEF-CVE-2026-4396x/-43971 set does not apply); **bandit locked at 1.12.5**, the exact fix release for EEF-CVE-2026-74836 / EEF-CVE-2026-75484 — no HIGH advisories outstanding.
- **Outdated (runtime):** all 14 direct runtime deps are at their latest stable (descripex 0.13.0, oban 2.23.1, phoenix 1.8.12, phoenix_live_view 1.2.10, ecto_sql 3.14.0, postgrex 0.22.4, req 0.7.3, anubis_mcp 2.0.0, tzdata 1.1.4, oban_web 2.12.6, bandit 1.12.5, …) — zero safe-bump backlog.
- **Outdated (dev/test):** credo, dialyxir, styler, ex_doc, doctor, sobelow, ex_dna, reach, exograph, igniter, vibe_kit, ex_slop, tidewave, lazy_html, ex_unit_json, dialyzer_json all at latest stable except the two constraint-blocked items above.
- **Unused deps:** every other runtime dep has verified call sites (descripex, nimble_options, anubis, tzdata via `config :elixir, :time_zone_database`, oban_web, phoenix_pubsub, phoenix_html, postgrex, bandit) — only `req` failed the check.
- **Duplication/overlap:** dev-tool stack is intentionally layered (styler=formatter, credo+ex_slop=lint plugin host, dialyxir+dialyzer_json=engine+reporter, ex_dna/reach/exograph=distinct analyses) — no genuine conflict found.
- **Licenses:** runtime tree is MIT/Apache-2.0 throughout except the LGPL-3.0 anubis_mcp flagged above (spot-checked transitives: peri, json_spec, hackney, finch, jason, telemetry, thousand_island, websock_adapter, plug — all permissive).

## Score

**Dependency health: 90/100** — fully current and advisory-clean lockfile with no vulnerable packages; deductions only for one dead runtime dep (req), an LGPL runtime dependency needing sign-off, and a ref-less git dependency.
