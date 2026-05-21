---
sha: f09ac5591e0eaa0031a40aeb1ba6c5a494ac6390
short_sha: f09ac55
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: clean — fast-path
codex_status: not-dispatched
audited_by: audit-review v1
---

# Audit: fix: renumber dogfood discovery task to 27 (rmap new assigned colliding id 1)

**Reason for fast-path:** 6 LOC, no production-code paths touched.
**Files touched:** `ROADMAP.md`, `roadmap/data.json`, `roadmap/tasks.toml`.

This commit resolves the duplicate-`id` bug Codex independently flagged when
auditing `50c1b77` (the dogfood batch's `rmap new` assigned the colliding
`id = "1"`). Within-range fix — no separate finding.
