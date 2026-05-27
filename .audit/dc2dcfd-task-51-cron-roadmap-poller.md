---
sha: dc2dcfdffbe78daad1ea8dc95bd616d339441ab4
short_sha: dc2dcfd
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — user directive; agent delivery + adjacent integration fix in f092558)
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 51 Cron-driven autonomous roadmap polling via Oban.Plugins.Cron

**Original commit:** dc2dcfd — agent delivery (Codex)
**Author:** harness@localhost (worktree)
**Files touched:** 6 (3 lib, 1 config, 2 test)
**LOC:** +431 / -9

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | acceptance | — | `Oban.Plugins.Cron`-driven polling via `Harness.Cron.RoadmapPoller`: ✅ | met |
| 2 | — | acceptance | — | Opt-in via `:cron_polling, enabled: false` default: ✅ | met |
| 3 | — | acceptance | — | Queue-headroom + AgentRegistry-gated dispatch (no runaway): ✅ | met |
| 4 | — | acceptance | — | Per-project iteration via `ProjectRegistry.list/0`: ✅ | met |

Notable correct shapes:

- `enabled?/0` defaults to `false` — autonomous dispatch never fires by surprise.
- `queue_headroom?/1` counts jobs in `available|scheduled|executing|retryable` states and blocks dispatch above the per-project cap. Prevents the "cron stampedes the queue" failure mode.
- `AgentRegistry.select/1` is called before enqueue — the same quota-aware fail-over the manual dispatch path uses, so cron polling inherits the existing capability/availability gating.
- `:roadmap_ingest` and `:queue_headroom?` Application env keys provide clean test seams (same pattern as `Harness.Run.Worker`'s `:run_starter` seam from `b2e272a`).
- Errors are logged at `:debug` level — no Sentry spam from the heartbeat.

The `next_tick/1` nested-with-case originally introduced here was flattened by the adjacent `f092558` integration commit (with rationale captured for the `apply/2` use against Oban's opaque `Cron.Expression` type, and the unreachable `adapter_for_agent/1` catchall removed). Both audited together.

## Auto-applied fixes

— None (integration fixes already landed in `f092558`).

## Codex second-opinion

Status: not-dispatched (Codex authored this commit; second-opinion would be Claude — verification stack + the adjacent integration fix already serve that role)
