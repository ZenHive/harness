---
sha: 89ccebfc95c26b4e5dda1906e5858db024996501
short_sha: 89ccebf
audited_at: 2026-06-09
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: surface reviewer/recovery agent identity in run feed + dashboard

**Author:** E.FU · **Files:** 4 (lib/harness/run.ex, run/status.ex, dashboard/live.ex, +2 tests) · **LOC:** ±89

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | (none) | — | Mechanical observability: stage-active agent identity surfaced; fact-only | clean |

## Notes
Adds `reviewer_adapter`/`recovery_adapter` to `Run.Status`, populated live via `agent_kind_for/1` and on rehydrated rows via registry reverse-map (recovery not persisted → nil). `stage_agent_label/1` names the active-stage agent. THE MANTRA holds — counts which agent works which stage, no judgment. Well-tested (both new fields + fallback-to-implementer covered).

## Codex second-opinion
Status: dual-reviewer. No findings on this commit. Corroborated nothing (clean). No Codex-only flags.
