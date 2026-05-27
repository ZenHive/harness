---
sha: 2bce2a24937cc5b71181734b3f89efb3233cd181
short_sha: 2bce2a2
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: findings-noted
codex_status: not-dispatched (tight pass — user directive; agent delivery graded by harness verification stack)
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 46 %Harness.Project{} struct + in-memory ProjectRegistry; Run takes Project

**Original commit:** 2bce2a2 — agent delivery (Cursor)
**Author:** harness@localhost
**Files touched:** 29 (12 lib, 17 test/support/fixtures)
**LOC:** +746 / -101

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 3 | doc-gap (spec) | lib/harness/project_registry.ex:fetch_check_stack/1 | `@spec` excludes `{:error, {:unknown_preset, atom()}}` returned by `Preset.fetch/1`; passed dialyzer because the only caller (`init/1`) logs+swallows | Noted (not fixed in tight pass — already partially patched by a later commit catching the related `is_atom(nil)` bug, see current file); `Preset.fetch/1` error type is documentary, not propagated |
| 2 | — | acceptance | — | %Harness.Project{} struct: ✅ name, source, check_stack, roadmap_path, concurrency_cap (matches CLAUDE.md § Phase-7) | met |
| 3 | — | acceptance | — | ProjectRegistry GenServer with register/lookup/list/unregister: ✅ | met |
| 4 | — | acceptance | — | Run takes Project (not just repo_path): ✅ (Batch.loop_context/8 spec inherited bug → fixed by f5bc4a1) | met (via fixup commit) |

`f5bc4a1` (the spec fixup) is the artifact of this commit's only correctness regression — the Cursor agent updated `Batch.loop_context/8`'s callers but not the `@spec`, dialyzer flagged it, and the cascade was fixed in a follow-up. Captured in that commit's audit report. The Rust preset addition is clean (4 checks, `--message-format=json` ready for parser plumbing).

## Auto-applied fixes

— None (tight pass; finding #1 is documentary and a later commit already added a nil-guard adjacent to the affected function).

## Codex second-opinion

Status: not-dispatched (user-directed tight pass; agent delivery already graded by harness verification stack + adjacent fixup commits)
