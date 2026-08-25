# harness — Project Health Audit · 2026-08-25

Full 5-track audit (`/phx:audit --full`) on `main` @ `69b24aa`. Static analysis
across the board; sobelow run live (green), coverage pass noted where pending.

## Executive summary

**Overall: 78/100 — B−.** A mechanically disciplined OTP core (argv-only
subprocess spawning, parameterized SQL, `:temporary`/`:one_for_one` run
supervision, an advisory-clean lockfile) carrying two classes of real debt: a
handful of **architectural security gaps** the loopback bind alone doesn't
close, and **observability-surface performance** (uncached Postgres reads ×
5-second LiveView ticks, full-table run-record loads per settle event) that
degrades as the run ledger grows. No critical findings; five High findings, all
fixable without touching the accepted hub-and-spoke shape.

| Category | Score | Ceiling | Worst finding |
|---|---:|---|---|
| Dependencies | 90 | low | LGPL-3.0 `anubis_mcp` in runtime tree; ref-less git dep |
| Tests | 82 | medium | 3 `Process.sleep`-as-sync sites; `--cover` unverified |
| Architecture | 78 | medium | 1,488-line dashboard LiveView mixes render + reconciliation |
| Security | 74 | **serious** | unauthenticated MCP control plane (DNS-rebinding reachable) |
| Performance | 66 | **serious** | N+1 settings reads × 5s ticks; full-table KPI loads per settle |

## Critical issues

None. The highest-severity findings are High, concentrated in security and the
dashboard performance surface.

## Top recommendations (cross-cut, ranked by blast-radius ÷ effort)

1. **[SEC-H1] Add an `Origin`/`Host` guard plug to `/harness/mcp`.** The whole
   "operator-only localhost" posture rests on it; DNS rebinding makes an attacker
   page same-origin with a control plane that registers projects, dispatches
   agents, and lands branches. Smallest change, largest reduction.
   `lib/harness/dashboard/mcp_plug.ex:52`.
2. **[SEC-H2] Delete `.harness/review.json` at the entry into `:reviewing`.**
   Verified: no `File.rm` of the artifact exists anywhere in `lib/harness/run/`.
   The gate's own input is implementer-writable, and via prompt injection →
   pre-written `{"verdict":"approve"}` + a silent reviewer → unreviewed code
   auto-lands. Three lines; mantra-compatible (counts a fact, judges nothing).
   `lib/harness/run/actions/reviewing.ex`.
3. **[SEC-H3] Validate source-URL scheme + add `--` to `git clone`.** Verified:
   no scheme validation before the clone. `ext::sh -c …` is code execution and a
   leading `-` is parsed as an option. Chains straight out of H1.
   `lib/harness/project/source/github.ex:104`.
4. **[PERF-H2/H3] Cache SettingsStore blocks + move CLI catalog probes off the
   render path.** `SettingsLive`'s 5s `:meta_tick` drives 50–150 identical
   `harness_settings` point reads and can shell out to five agent CLIs
   *synchronously* inside the LiveView process. Give SettingsStore the
   write-through cache `Harness.Config` already has; serve stale-while-revalidate
   for the catalog. `lib/harness/model_availability.ex:405,634`.
5. **[PERF-H1] Push KPI rollups into SQL + debounce the settled-event refresh.**
   `aggregate_review_stuck_causes/1` and `aggregate_recovery_facts/1` are
   `list_run_records(store, [])` — full table, decoded to structs — re-run per
   `:harness_run_settled` event per client. `result_store.ex:451,479`.
6. **[ARCH-2] Extract history reconciliation out of `Dashboard.Live`.** Move
   `reconcile_history_*` / `landed_entry?` into a plain module callable without a
   socket (and from tests). `lib/harness/dashboard/live.ex`.

## Action plan

**Immediate (this week — security invariants + a test each):**
- SEC-H1, H2, H3 above. Add the two cheap regression tests the security track
  names: MCP plug 403s a foreign `Origin`; a pre-written `review.json` cannot
  approve a run.
- [DEPS] Confirm bandit stays ≥ 1.12.5 (currently locked exactly there — the fix
  release for the two HIGH EEF advisories). Drop the unused `req` runtime dep.

**Short-term (this month — perf + hygiene):**
- PERF-H1/H2/H3, then M2 (retention sweep → partial index or daily cron; it
  currently range-scans on every run-record insert), M5 (shared roadmap-summary
  cache; `connected?/1`-gate the dashboard mounts).
- [SEC-M1] Slug-validate `project.name`; canonicalize `roadmap_path`/`{:local}`.
- [SEC-M2] Stop persisting set-valued agent env into `oban_jobs.args` (plaintext,
  rendered in Oban Web).
- [TEST] Fix the 3 `chat/session_test.exs` fixed-sleep sites → monitor +
  `assert_receive {:DOWN, …}` or bounded poll.

**Long-term (as convenient):**
- [ARCH-2/3] Dashboard.Live reconciliation extraction; factor await-polling
  helpers out of the `Dispatch` facade.
- [SEC-L1] Runtime-override the LiveView/session signing salts; un-commit the
  personal notify path (L2).
- [DEPS] LGPL-3.0 `anubis_mcp` sign-off; tag + `ref:`-pin `harness_agent_adapter`.
- [PERF-M4] `LineBuffer.split/2` chunk-scan + remainder copy + a partial-line cap
  (currently unbounded on a single giant line — correctness-adjacent).

## Cross-category correlations

- **SEC-H1 → SEC-H3 → SEC-M1 is one chain.** DNS-rebound page → unauthenticated
  `register_project` MCP tool → `ext::` URL into `git clone` (H3) or a
  `../` project name into the worktree root (M1) → code execution / arbitrary
  writes as the operator. Fixing H1 defangs the remote reach of all three; the
  URL/name validations (H3/M1) are the defense-in-depth layer behind it.
- **The dashboard is the weak surface in two tracks at once.** `Dashboard.Live`
  is both the architecture finding (1,488 lines, mixed concerns) and the
  performance epicenter (roadmap shell-outs per tick, full-table KPI loads,
  synchronous CLI probes). The reconciliation/aggregation logic that ARCH-2 wants
  extracted is the same code PERF-H1/M5 wants cached and SQL-pushed — one
  extraction into a shared, cacheable module serves both tracks.
- **The core is genuinely solid across every track.** Ports, gen_statem run
  lifecycle, Oban dispatch (queue-per-project caps, landing limit 1,
  `{project,task}` uniqueness), lander git safety (`merge-base --is-ancestor`,
  never `--force`), and per-agent transcript parsers all came back clean in
  architecture, performance, security, and test coverage simultaneously. The debt
  lives at the edges — dashboard observability and the MCP/clone attack surface —
  not in the orchestration engine.

## Method notes

- Security agent had no Bash; the orchestrator ran `mix sobelow --skip --format
  compact` on its behalf → **exit 0, zero live findings** (only the expected
  "cannot find router" warning). H1–H3 verified against source by the orchestrator.
- Test agent had no Bash; `mix test.json --cover` was run separately by the
  orchestrator to verify tier claims — see the coverage addendum below if present.
- `mix hex.outdated` crashes on this hex (2.4.2 MatchError on registry timeouts);
  deps audited via the hex.pm HTTP API instead.

## Coverage addendum (measured — `mix test.json --cover`, integration excluded)

**1945 passed, 0 failed. Overall line coverage: 83.66% (8788/10504)** — above
the 80% standard tier. This resolves the test track's one open question: it
confirms one High finding and sharpens it into a concrete gap.

Critical-tier modules (project bar ≥95% — money/signing/git-push surfaces):

| Module | Coverage | vs ≥95% |
|---|---:|:--:|
| `Harness.Run` | 98.53% | ✓ |
| `Harness.Lander.Worker` | 100% | ✓ |
| `Harness.Git` | 96.0% | ✓ |
| `Harness.Lander.Resolver` | 93.51% | ⚠ |
| `Harness.Git.TargetSync` | **88.89%** | ✗ |
| `Harness.Dispatch` | 88.36% | ✗ |
| `Harness.Lander` | 86.99% | ✗ |
| `Harness.Worktree` | 85.64% | ✗ |

**`Harness.Git.TargetSync` at 88.89% is the finding the test agent flagged by
name.** CLAUDE.md calls it out explicitly as the guard against a self-land
mutating the running node's own checkout — a critical-tier module sitting ~6
points under bar. `Lander` (87%), `Worktree` (86%), and `Dispatch` (88%) are also
below 95% if treated as critical (they drive `git push` / land operations). Per
the "raise coverage before mutating" rule, any future change to these modules
should lift them to tier first. Not a defect in shipped behavior — the scenario
coverage is thorough — but the numbers are now measured, not proxied.

Per-track detail: `.claude/audit/reports/{arch-review,perf-audit,security-audit,test-audit,deps-audit}.md`.
