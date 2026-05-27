---
sha: 51f8d9bbd5713be0ff3a0b42dad75d75447513a1
short_sha: 51f8d9b
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — Codex delivered this commit; audit is the post-merge bookkeeping)
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 48 Oban-backed dispatch + queue-per-project

**Original commit:** 51f8d9b — agent delivery (Codex)
**Author:** E.FU (integration commit; agent author = harness@localhost in worktree)
**Files touched:** 22 (8 lib, 3 config/migration, 2 test, 9 misc)
**LOC:** +577 / -10

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 1 | cosmetic | lib/harness/oban.ex:`oban_opts/0` | `Keyword.put_new(:name, ...)` followed by `Keyword.put(:name, ...)` — the put_new is redundant | Noted, skip (priority < 3) |
| 2 | — | acceptance | — | Oban supervisor with queue-per-project: ✅ | met |
| 3 | — | acceptance | — | Harness.Run.Worker wraps existing gen_statem; preserves in-flight on restart via Oban job row: ✅ | met |
| 4 | — | acceptance | — | Failure-classified retry maps to :snooze (quota/transient) / :cancel (terminal): ✅ | met |

The `agent_for_adapter/1` hardcoding to `Claude|Codex|Cursor` (and the explicit fail-closed clause for anything else) is correct — non-delegatable adapters (Grok/Antigravity/Pi) are dispatched via the two-step `Harness.Roadmap.ingest/2` + direct `Harness.Run.Supervisor.start_run/4` per CLAUDE.md, not via Oban. The hardcoding is the right shape.

The integration-touch notes in the commit body (plt_add_apps, .tool-versions split, `to_oban_result/1` refactor avoiding partial `%Oban.Job{}`) are exactly the kind of post-Codex polish that warrants this commit being authored by E.FU rather than the raw agent worktree. Earmark IAL collision avoidance in CHANGELOG also clean.

## Auto-applied fixes

— None (no priority-3+ findings).

## Codex second-opinion

Status: not-dispatched (Codex authored this commit; second-opinion would be Claude grading Codex's own delivery — the verification stack already serves that role per CLAUDE.md § Evaluator Separation, and 425/425 offline tests + 0 dialyzer warnings on the integrated state confirm)
