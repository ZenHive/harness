---
sha: 95fe425
short_sha: 95fe425
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: clean — fast-path
codex_status: not-dispatched
audited_by: audit-review v1
---

# Audit: chore: drop pre-fix-era leaked harness rule files

**Reason for fast-path:** 56 LOC, no `lib/` paths touched — deletes orphan `AGENTS.md` + `.cursor/rules/harness-operational.mdc` artifacts (resolved upstream by Task 36's cleanup hook).
**Files touched:** AGENTS.md (deleted), .cursor/rules/harness-operational.mdc (deleted), .gitignore
