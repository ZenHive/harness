---
sha: a182ccc6878c0178ed814dcd0cb356dee8f35f40
short_sha: a182ccc
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: findings-noted
codex_status: not-dispatched (tight pass — user directive)
audited_by: audit-review v1
---

# Audit: harness: task 50 — Phoenix LiveView dashboard + embedded Oban Web

**Original commit:** a182ccc — `harness: task 50 — Phoenix LiveView dashboard + embedded Oban Web (milestone v0_5 complete)`
**Author:** E.FU (hand-built per Phase-7 exception in CLAUDE.md)
**Files touched:** 22 (8 lib, 2 layout, 2 test, configs, mix)
**LOC:** +872 / -35

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | bug | lib/harness/dashboard/live.ex:`filter_runs/2` | Per-project filter checks `entry.project_name` (not on `StatusView.run_entry`) and `entry.status.run_id` prefix (current run_ids are `run-<ts>-<rand>`, no project prefix) — selecting a project shows zero runs. The "All projects" path still works. | **Noted, NOT auto-applied** — fix requires contract change to `StatusView.run_entry` to carry `project_name` plus a `StatusView.run_entry/1` plumb. User-directed tight pass; deferred. Cold-path dashboard impact only. |
| 2 | — | acceptance | — | `Harness.Dashboard.Endpoint` standalone Bandit, conditional behind `:dashboard, :enabled` + `Code.ensure_loaded?(Bandit)`: ✅ | met |
| 3 | — | acceptance | — | Oban Web mounted at `/harness/oban`, custom LiveView at `/harness` and `/harness/runs/:run_id`: ✅ | met |
| 4 | — | acceptance | — | Live transcript pane (`Phoenix.PubSub` topic `harness:run:<id>:transcript`, 200 KiB bounded buffer): ✅ | met |
| 5 | — | acceptance | — | `:on_output` callback on `AgentAdapter.Driver.run/3` fans chunks to transcript: ✅ | met |
| 6 | — | acceptance | — | Bandit `optional: true` so mountable consumers aren't forced into a second HTTP server: ✅ | met |

Notable correct shapes:

- `Phoenix.PubSub` added to Application supervision tree BEFORE the Endpoint (so transcript broadcast has a bus regardless of env) — comment captures the ordering invariant.
- Conditional `dashboard()` returns `[]` when `enabled: false` OR Bandit missing — clean tri-state with an info log on the missing-Bandit branch (vs crashing the app).
- `Transcript.subscribe/unsubscribe/broadcast` all guard on `Process.whereis(@pubsub)` — driver embedded in non-dashboard contexts never fails on missing bus.
- `:on_output` hook in `Driver.loop/7` is `rescue`+`catch`-wrapped — a faulty hook can never abort the agent run.
- Oban Web scope mounted BEFORE the dashboard LiveView scope in the router — correct precedence so `/harness/oban` routes to Oban Web rather than the LiveView's `/harness/runs/:run_id` pattern.

## Auto-applied fixes

— None applied (Finding #1 deferred per user-directed tight pass; surfacing the bug honestly is the audit value).

## Discuss-tier resolutions

— Finding #1 resolution path (when followed up): add `project_name` field to `StatusView.run_entry` type and populate it in `StatusView.run_entry/1`; update `filter_runs/2` to a single `entry.project_name == project_name` comparison; update `mix harness.status` text renderer if it iterates entries by project. Reversible, contract change confined to two files.

## Codex second-opinion

Status: not-dispatched (user-directed tight pass; finding #1 surfaced by direct grep against the StatusView type)
