---
sha: f0925589d377c11bbf62a120a61694f504970a88
short_sha: f092558
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — user directive)
audited_by: audit-review v1
---

# Audit: harness: integration fixes for task 51 — flatten next_tick/1 + remove unreachable adapter clause

**Original commit:** f092558 — `harness: integration fixes for task 51 — flatten next_tick/1 + remove unreachable adapter clause`
**Author:** E.FU
**Files touched:** 1
**LOC:** +22 / -12

## Findings

None substantive. The flatten extracts three helpers (`compute_next_tick/1`, `next_at/2`, `handle_next_at/1`) to satisfy Credo nesting limits, restoring `apply/2` on `Oban.Cron.Expression.next_at/2` (with `credo:disable-for-next-line Credo.Check.Refactor.Apply` + an explanatory comment) because dialyzer cannot pierce Oban's opaque expression type — rationale captured inline. The `adapter_for_agent/1` cascade clause delete + narrowed spec (`:claude | :codex | :cursor`) is consistent with how items are sourced (only those three agents are valid via `rmap delegate`).

The narrowed spec is correct only if `Harness.Roadmap.Item.agent` is constrained upstream to that atom set — verified by inspection: `defstruct agent: :claude | :codex | :cursor` is enforced by `Roadmap.ingest/2` matching against those literals. The delete is safe.

## Auto-applied fixes

— None needed.

## Codex second-opinion

Status: not-dispatched (34 LOC integration fix; rationale in inline comments)
