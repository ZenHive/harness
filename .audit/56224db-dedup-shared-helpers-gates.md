---
sha: 56224dba3d06aa451bc479611c9ce955c6f44fff
short_sha: 56224db
audited_at: 2026-06-22
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: dedup shared helpers; add ex_slop/ex_dna/reach gates + mix ci

**Original commit:** 56224db — hand-built (setup-guide alignment + 9-clone grind)
**Author:** E.FU
**Files touched:** 32 (23 lib/, mix.exs, .credo.exs, .reach.exs, .sobelow-skips, CLAUDE.md, AGENTS.md, mix.lock, 2 tests)
**LOC:** ±990

Behavior-preserving refactor: extracted 9 `ex_dna --max-clones 0` AST clones into shared helpers; wired ex_slop/ex_dna/reach into the mix.exs gates + `mix ci`.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5   | doc-gap  | mix.exs:210, CLAUDE.md:78 | Docs called `reach.check --arch --smells` a "smell gate" / "a red here is real debt" — but `--smells` is advisory (exits 0 without `--strict`); only `--arch` gates | Applied: clarified --arch gates / --smells advisory in both; AGENTS.md regenerated |

## Extraction review (behavior-preservation — the critical axis)

Codex independently verified all 9 extractions are behavior-preserving — no divergence in defaults, tuple shapes, nil handling, guards, or key stringification. Specific confirmations:
- `Harness.Facet.normalize/1` identical to both original `normalize_facet` defps (map-only, drops nils, `to_string/1` keys, non-map → `%{}`).
- `ResultStore.fetch_run_record/1` correctly `@doc false` and NOT `api()`-annotated — `Harness.AgentEconomyTest` manifest invariant passes (24 tests).
- `RetryPolicy.retry/2` preserves attempt semantics (`max_retries: 2` ⇒ 3 total attempts).
- `ex_dna --max-clones 0` now reports 0/0 clones (was 9).

## Auto-applied fixes

- mix.exs:210 — comment now distinguishes `--arch` (gates, non-zero exit on violation) from `--smells` (advisory, exits 0 without `--strict`).
- CLAUDE.md:78 — same clarification in the Toolchain section; smell findings are a backlog signal, not a build break.
- AGENTS.md — regenerated from the edited CLAUDE.md (`sync-agents-md.sh`).

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (Codex priority 5; Claude knew the `--smells` semantics independently from the prior session).
Codex-only findings (verified): none beyond #1.
Codex-only findings (discarded as over-flag): none.
Extraction divergence found: none (9/9 clean).
