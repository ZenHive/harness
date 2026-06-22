---
sha: 31c8de02ca6414735a8df7129377cb96429fc206
short_sha: 31c8de0
audited_at: 2026-06-22
auditor_model: claude-opus-4-8
verdict: clean — roadmap-data only
codex_status: not-dispatched
audited_by: audit-review v1
---

# Audit: roadmap: tasks 327/328/329 — AgentAdapter extraction decoupling

**Reason for light review:** 208 LOC but prod=0 — pure rmap task definitions
(roadmap/tasks.toml + rendered roadmap/data.json). No Codex dispatch.

**Files touched:** roadmap/data.json, roadmap/tasks.toml

## Review

Three coupled decoupling tasks (327 rule-content seam inversion, 328 break
Driver→Reflex→Worktree.Isolation→AgentAdapter cycle, 329 extract-to-hex
decision spike) added with scores, dependencies, and acceptance criteria.
Task-as-prompt shape, no over-specification, no hedging. Clean.
