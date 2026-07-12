# Dependency Audit — harness

Date: 2026-07-12
Scope: `mix.exs` / `mix.lock` (96 locked packages). `mix hex.outdated`, `mix hex.audit` run against the live registry; CVE claims verified via GHSA/OSV/vendor advisories (cited inline).

## Summary

- `mix hex.audit`: **no retired packages**.
- `mix hex.outdated`: **every runtime and dev/test dep is current** except `volt` (dev-only, unused — see below).
- **Security**: swept Phoenix, Plug, Bandit, Ecto, Postgrex, Oban/Oban Web, Mint against 2026 advisories. Every pinned version is **already patched** — the repo's most recent commit (`033bf8d`) bumped exactly the versions that closed the open CVEs. No exploitable version found.
- **License**: one runtime dependency, `anubis_mcp`, is **LGPL-3.0** (copyleft) — flag for legal review given the public repo.
- **Unused deps**: `dune`, `hammer`, `phoenix_iconify` have zero references anywhere in `lib/`, `test/`, config, or mix aliases — pure dead weight. `boxart` is borderline (enables `reach`'s optional terminal-graph viz, but nothing in the repo exercises it).
- **Tooling health**: `exograph` is still pinned to a `github:` SHA with a stale TODO ("wait for a hex release > 0.8.0") — hex.pm has since shipped **0.9.12**; the blocking condition is gone and the pin should convert to a hex dep.

---

## Findings, ranked by severity

### 1. [Moderate] `anubis_mcp` (runtime dep) is LGPL-3.0 — copyleft license on a required dependency

`{:anubis_mcp, "~> 1.6"}` (locked 1.6.2) is a hard runtime dependency — it backs `Harness.Dashboard.MCPServer`, not an optional/dev tool. Its license is **GNU LGPL v3** (confirmed from the upstream `LICENSE` file at `github.com/zoedsoupe/anubis-mcp`). LGPL is copyleft-lite: fine for dynamic linking in traditional ecosystems, but the BEAM release model (compiling a dependency straight into a `mix release` / escript) makes the "dynamic linking" boundary that LGPL relies on ambiguous, and LGPL still requires that users of the combined work be able to relink/modify the LGPL'd component. Since `harness` is a public repo (per its own CLAUDE.md), this is worth a one-time legal/licensing sanity check rather than a silent accept. No other checked runtime dep (Phoenix/Ecto/Postgrex/Oban/Req/Bandit family) carries a non-permissive license — all are Apache-2.0/MIT.

*(Sources: [anubis_mcp on Hex.pm](https://hex.pm/packages/anubis_mcp), [zoedsoupe/anubis-mcp LICENSE](https://github.com/zoedsoupe/anubis-mcp))*

### 2. [Minor] Three dev/test deps have zero usage anywhere in the repo — orphans

Cross-referenced every non-mainstream `only: [:dev, :test]` dep against `lib/`, `test/`, `config/`, `.credo.exs`, `.formatter.exs`, `.reach.exs`, and `mix help` output. Three have **no code reference, no mix-task wiring, no config entry** anywhere:

| Dep | Declared | What it does | Evidence of use |
|---|---|---|---|
| `dune` (`~> 0.3`) | mix.exs:162 | Sandboxed evaluator for untrusted user code (playgrounds/REPLs) | None — only appears as literal fixture text inside `test/harness/dep_freshness/provider/elixir_test.exs` (a parsed `mix hex.outdated` sample string, not an API call) |
| `hammer` (`~> 7.3`) | mix.exs:159 | Rate limiter w/ pluggable backends (ETS/Redis) | None |
| `phoenix_iconify` (`~> 0.1`, locked 0.3.5) | mix.exs:160 | Icon set manager for Phoenix templates | None — dashboard heex templates use **zero** icons (no `hero-*`, no `<.icon>` component, no `Iconify.*` calls); the package's own mix tasks (`phoenix_iconify.audit/.cache/.prefetch`) would currently report nothing to manage |

None of these show up in `.credo.exs` plugins, `.formatter.exs` plugins, `.reach.exs` policy, or any `mix.exs` alias step. Safe to remove unless there's a near-term plan to actually use them (rate limiting the MCP/dashboard endpoints would be the obvious future use for `hammer`, but nothing wires it in today).

**Borderline, not counted as a hard orphan:** `boxart` (`~> 0.3`) is `reach`'s optional dependency for terminal ASCII/Unicode graph rendering (`mix reach.graph`-style output) — declaring it directly in harness's own `mix.exs` is what "activates" that optional reach feature. Nothing in the repo's docs/aliases currently invokes it, but it has a real, documented purpose via a peer tool rather than being pure deadweight.

### 3. [Minor] `exograph` git pin has outlived its own stated reason

```
# TODO: pin to hex once a release > 0.8.0 ships — GitHub HEAD carries a fix we need
# that is NOT yet in hex 0.8.0; stay on the github dep until then. (Also: 0.8.0 still
# pins volt ~> 0.11.1, which is what holds volt back from 0.14.)
{:exograph, github: "elixir-vibe/exograph", only: [:dev, :test], runtime: false},
```

hex.pm's current published `exograph` is **0.9.12** (checked live) — well past the stated "> 0.8.0" trigger. The git pin (SHA `861133558ccd`) is dev/test-only so it's low risk, but the comment's own unblock condition has been satisfied; the dependency should be converted to a hex requirement (e.g. `{:exograph, "~> 0.9"}`) or the TODO updated to explain why the git pin is still needed if there's a newer reason.

### 4. [Nitpick] `volt` has a pending minor bump, but it's dead code anyway

`mix hex.outdated` flags `volt 0.14.12 → 0.16.0` ("Update possible" — held back by `release_kit`'s `~> 0.14` transitive constraint, not by harness's own `~> 0.11` pin, which is loose enough to allow 0.16). `volt` is a frontend build tool (dev server/HMR) — grepped `lib/`, `test/`, `config/` and found **zero references**; it's not driving the dashboard's asset pipeline today. Low priority precisely because nothing depends on it functioning at any particular version.

---

## Security sweep detail (all clear)

Checked every pinned version of the notable runtime deps named in scope against 2026 GHSA/OSV/CVE advisories. **Every one is already on a patched release** — no action needed, included here as the audit trail:

| Package | Pinned | Advisory checked | Affected range | Status |
|---|---|---|---|---|
| Phoenix | 1.8.9 | [CVE-2026-32689](https://osv.dev/vulnerability/EEF-CVE-2026-32689) — long-poll NDJSON memory-amplification DoS | 1.7.0–1.7.21, 1.8.0–1.8.5 | ✅ fixed since 1.8.6 |
| Phoenix | 1.8.9 | [CVE-2026-56811](https://cve.threatint.eu/CVE/CVE-2026-56811) — unbounded channel-join process spawn | …–1.8.8 | ✅ fixed exactly at 1.8.9 |
| Plug | 1.20.3 | [GHSA-468c-vq7p-gh64](https://github.com/elixir-plug/plug/security/advisories/GHSA-468c-vq7p-gh64) — multipart header-parsing DoS | up to 1.19.2-line | ✅ fixed |
| Plug | 1.20.3 | GHSA-j43x-5hjq-rgxf / [CVE-2026-54892](https://vulnerability.circl.lu/vuln/cve-2026-54892) — query-param decode blowup | …–1.19.2 | ✅ fixed |
| Plug | 1.20.3 | [GHSA-wpmj-jh88-rpgm](https://github.com/elixir-plug/plug/security/advisories/GHSA-wpmj-jh88-rpgm) — cookie-attribute injection | 1.20.0–1.20.2 | ✅ fixed exactly at 1.20.3 |
| Bandit | 1.12.0 | [CVE-2026-42788](https://cve.threatint.eu/CVE/CVE-2026-42788) — HTTP/2 oversized-frame buffering | 0.3.6–1.10.x | ✅ fixed since 1.11.0 |
| Bandit | 1.12.0 | [GHSA-c67r-gc9j-2qf7](https://github.com/mtrudel/bandit/security/advisories/GHSA-c67r-gc9j-2qf7) — CL.CL request smuggling | …–1.10.x | ✅ fixed since 1.11.0 |
| Bandit | 1.12.0 | [GHSA-375f-4r2h-f99j](https://github.com/mtrudel/bandit/security/advisories/GHSA-375f-4r2h-f99j) — plaintext scheme spoofing | 1.0.0–1.10.x | ✅ fixed since 1.11.0 |
| Bandit | 1.12.0 | [GHSA-frh3-6pv6-rc8j](https://github.com/mtrudel/bandit/security/advisories/GHSA-frh3-6pv6-rc8j) — WS permessage-deflate OOM (only if `compress: true`) | 0.5.8–1.10.x | ✅ fixed since 1.11.0 |
| Postgrex | 0.22.3 | [CVE-2026-32687](https://nvd.nist.gov/vuln/detail/CVE-2026-32687) — SQL injection via `Notifications.listen/3` channel name | 0.16.0–0.22.1 | ✅ fixed since 0.22.2 |
| Oban Web | 2.12.6 | CVE-2026-48593 — unbounded cron-expression range allocation (~2.4GB) | 2.12.0–2.12.4 | ✅ fixed since 2.12.5 |
| Mint (transitive, via Finch/anubis_mcp) | 1.9.1 | CVE-2026-48862 — PUSH_PROMISE flood resource exhaustion | …–1.8.x | ✅ fixed since 1.9.0 |
| Oban core, Ecto core | 2.23.0 / 3.14.1 | targeted search | — | no advisory found for either |

`plug_cowboy`'s atom-exhaustion CVE-2026-32688 does not apply — harness has no `plug_cowboy` in `mix.lock` (Bandit-only HTTP stack).

---

## Not flagged (checked, clean)

- **Runtime dep count is small and current.** `descripex`, `nimble_options`, `ecto_sql`/`ecto`, `postgrex`, `oban`, `req`, `phoenix`/`phoenix_live_view`/`phoenix_pubsub`/`phoenix_html`, `oban_web`, `bandit` (optional) — all "Up-to-date" per `mix hex.outdated`, all confirmed permissive licenses (MIT/Apache-2.0) except the one flagged above.
- **Dev/test tooling stack** (`credo`, `dialyxir`, `doctor`, `sobelow`, `styler`, `ex_slop`, `ex_unit_json`, `dialyzer_json`, `ex_ast`, `ex_dna`, `reach`, `ex_doc`) — all "Up-to-date", and all genuinely wired in via `mix.exs` aliases (`check.fast`/`check.dispatch`/`precommit`/`precommit.full`) or `.credo.exs` plugins. Not orphans despite no direct `lib/` module calls — that's the expected shape for CLI-invoked tooling.
- **`igniter` / `vibe_kit`** — installer-only mix tasks (`mix igniter.install vibe_kit`, `mix vibe_kit.install`); legitimately have no `lib/` call sites.

---

## Dependency Health Score: 88/100

Deductions: −6 for the LGPL-3.0 runtime dependency (real but not urgent — needs a licensing decision, not a code fix), −4 for three genuinely orphaned dev deps + one stale git-pin TODO, −2 for the trivial `volt` minor-version lag. No security deductions — every pinned version already closes its disclosed CVEs.
