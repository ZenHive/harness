---
sha: beaaa8248b807ef4b96ea93eb1bcf6f39f2e1d77
short_sha: beaaa82
audited_at: 2026-06-04
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 184 expand descripex/MCP orchestrator surface

**Files touched:** 2 lib/ files + tests **LOC:** ±498

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | discuss-trivial | doc-gap | project_registry.ex:83 | register/1 keyword/map clause not in api() doc | verified by-design; no fix |

## Auto-applied fixes
- (none)

## Discuss-tier resolutions
- register/1 (CORROBORATED Claude+Codex): both flagged that api() documents only the %Project{} path while the arity was widened to accept keyword/map attrs. Verified intentional: the keyword/map clause is in-process convenience carrying its own inline comment (lib/harness/project_registry.ex:76-81), the @spec already declares Project.t()|keyword()|map(), and the api() surface deliberately scopes to the struct contract because JSON callers route through Harness.Dispatch.register_project/6. A `@doc false` on the second clause is impossible — it would collide with the api()-generated `@doc` for register/1. No actionable, compiling fix; left as-is.

## Codex second-opinion
Status: dual-reviewer
Corroborated findings: 1 (register/1 doc — verified by-design, no fix)
Codex-only (verified): —
