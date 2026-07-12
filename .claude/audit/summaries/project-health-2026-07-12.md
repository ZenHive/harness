# harness — Project Health Audit (2026-07-12)

Branch `development`. Full 5-specialist audit. Quick pulse first: compile clean (warnings-as-errors), 2201 offline tests / 0 failures (66 integration excluded), no retired deps, 8 dependency cycles.

## Overall Health: **74/100 — C**

| Category | Score | Ceiling finding |
|---|---:|---|
| Dependencies | 88 | LGPL-3.0 runtime dep (`anubis_mcp`) on a public repo — legal review |
| Security | 82 | Dashboard + Oban Web + MCP have zero auth (loopback-bind is the only guard) |
| Tests | 78 | One live flaky test + merge-critical `Git.TargetSync` has zero tests |
| Architecture | 62 | 71-module (~30%) single strongly-connected cycle — no enforced layering |
| Performance | 58 | Postgres `:task_id` filter silently dropped → unbounded hot-path scan |

Weighted mean of the five = 73.6 → **74 / C**. Every score is *relative to this codebase*: the low two are structural/scaling debt in an otherwise correct, well-disciplined engine — none is an active outage at today's data volumes.

## Critical (fix first)

**P1 — `:task_id` filter silently ignored in the Postgres result store** (`lib/harness/result_store/postgres.ex:721-734`). `Run.Worker.recoverable_run_record/2` (`run/worker.ex:677`) passes `task_id:` expecting task-scoped filtering; `apply_filters/2` has no `:task_id` clause, so `_ -> q` drops it → Postgres returns **every** run record for the project on a hot dispatch/recovery path, saved from being *wrong* only by a client-side `Enum` filter. The Memory backend (`memory.ex:204`) filters generically and *does* honor `:task_id` — so the whole test suite (Memory-backed) is green while production Postgres diverges. This is the textbook "backend divergence evades per-task review" class. **Fix: add `:task_id` (+`:landed_sha`) clauses, a `:limit`, and indexes.**

**P2 — post-merge audit pulls every historical transcript blob to find one row** (`lib/harness/audit.ex:526`). `include_transcripts: true` with no limit, then `Enum.find` by `landed_sha` in Elixir. Grows unbounded with run history; every audit re-pays the full blob transfer.

## High

- **Fleet-wide KPI aggregates**: 5 unbounded/unindexed full-table scans recomputed on *every* settle event across *every* open `/harness/kpi` tab (`dashboard/kpi_live.ex:107`). Debounce + scope + `:limit`.
- **Redundant `git fetch` per unlanded run** instead of once per project, on mount and every 30s tick (`dashboard/live.ex:499`). Memoize per `project_name`.
- **71-module cycle** (`mix xref graph --format cycles`): run-lifecycle, lander, dashboard, chat, cron, MCP all mutually reachable — driver-surface core should depend one-way only; `Manifest` reverse-edges collapse the layering. (arch #1)
- **`Harness.Dispatch` is an 1821-line god module** blending dispatch, lifecycle control, admin, benchmarking, and routing — split into per-concern modules behind a thin facade. (arch #2)
- **No auth on dashboard/Oban Web/MCP** (`mcp_server.ex:56` explicitly "no MCP authorization"). Fine at loopback; silently becomes the consumer's problem when the router is mounted into a public endpoint. Add token/basic-auth gated for non-loopback binds. (sec #1)

## Medium / cleanup

- Missing indexes on `run_records`: `verdict`, `reviewer_adapter`, `task_id`, `landed_sha` (perf M1 — compounds every finding above).
- `Git.TargetSync` (lander/roadmap-critical, 3 branches) and `Store.EtsScope` have **zero dedicated tests** (test #2/#3).
- One **live flaky test** — `lander/resolver_test.exs:51`, documented `AgentRegistry` global-state pollution, annotated but unfixed; serialize `set_installed/2` mutators or use a supervised per-test registry (test #1).
- `AgentRegistry ↔ ModelAvailability` tight 2-module cycle; dead `GenServer.call` replies in `Cron.PendingDispatch` (`:174`/`:178`); transcript-pane per-chunk full-buffer copy; `ProjectRegistry.lookup/1` un-cached per-call Postgres read (perf M2/M3, arch #3/#4).
- 3 orphaned dev deps (`dune`, `hammer`, `phoenix_iconify` — zero references); stale `exograph` git-pin whose "> 0.8.0" unblock condition is long met (hex is at 0.9.12); add `[:safe]` to 3 `binary_to_term/1` sites (deps #2/#3, sec #2).

## Cross-category correlations

1. **P1 (perf) is really a test-coverage bug**: Memory backend honors `:task_id`, Postgres doesn't, tests run against Memory → the divergence is invisible to CI. Fixing it needs a Postgres-backed regression test, not just the filter clause.
2. **Missing indexes (M1) compound the unbounded aggregates (H1)** and the two point-lookup fixes (P1/P2) — do the migration alongside the filter fixes or they stay sequential scans.
3. **The 71-module cycle (arch) and the auth gap (sec)** share a root: no boundary between driver-surface *core* and its dashboard/MCP *consumers*. Enforcing that layering (`.reach.exs` boundaries) would both break the cycle and give the auth plug a clean seam to sit on.

## Action plan

**Immediate (1 PR):** P1 filter+index+Postgres regression test; P2 targeted `landed_sha` lookup. These are correctness-adjacent and cheap.
**Short-term:** debounce/scope KPI aggregates (H1) + per-project fetch memoization (H2) + the four missing indexes; `Git.TargetSync` tests; de-flake `resolver_test.exs`.
**Long-term:** split `Dispatch`; enforce core→consumer layering in `.reach.exs` to break the 71-cycle; add config-gated dashboard/MCP auth; remove orphan deps + convert `exograph` to hex.

## Method note

Per-category reports in `.claude/audit/reports/`. Coverage percentages were **not** quantified — `/tmp/audit-cov.json` was a run-summary, not `--cover` shape; re-run `mix test.json --cover --output <path>` for a per-module table (test #8). No cross-project score comparison implied — scores are internal-trend only.
