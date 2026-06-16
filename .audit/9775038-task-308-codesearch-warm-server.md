---
sha: 9775038819b17791c7701cf78d18eafc6aee7f82
short_sha: 9775038
audited_at: 2026-06-16
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
supersedes_conclusion: 178d7539 (audit(490da29)) "code in the range is sound"
---

# Audit (follow-up): task 308 CodeSearch warm DuckDB server

**Original commit:** 9775038 — `harness: agent delivery — task 308 CodeSearch: reuse a long-lived DuckDB server + dynamic repo instead of booting/tearing-down per query`
**Author:** harness (agent delivery, run run-1781589690215-f48d97d2)
**Files touched (original):** lib/harness/application.ex, lib/harness/code_search.ex, test/harness/code_search_test.exs (±656 LOC)

## Why a second pass

The range `89200d2..490da29` was already audited by `178d7539` (`audit(490da29)`), a **single-reviewer (Claude-only) pass** that fixed the doc/hygiene gaps (CHANGELOG entries for task 308 + the `/harness/projects` alias, `.gitignore` blank line, stale `.sobelow-skips` baseline) and concluded *"Code in the range is sound."* It noted the single-mailbox-crash tradeoff as an observation but filed no code change.

This follow-up adds the **mandatory Codex second-opinion** the prior pass lacked (Codex job task-mqgdzibx-v40crv). The dual-reviewer merge found three code-correctness/resource defects in `lib/harness/code_search.ex` the single-reviewer pass missed — exactly the failure mode mandatory-Codex exists to cover. Doc/hygiene findings are NOT re-applied here (already landed in 178d7539).

3-reasoner note: direct-to-`development` commit (no source PR), so no bot reasoners — Claude + Codex only.

## Findings (net-new vs 178d7539)

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug | code_search.ex:838 | `with_index` else-branch can't see resource_for's rebound `state` → orphans started server+repo on index-open failure (accumulates under a failure loop) | applied |
| 2 | 5 | bug | code_search.ex:1003 | `resource_key/2` omits `:prefix`/`:exograph_module` → cached resource reused for an incompatible query context (codex) | applied |
| 3 | 5 | bug | code_search.ex:480,508 | mtime-keyed ETS fact caches never evict → unbounded growth on a long-lived node (also flagged by codex) | applied (evict-on-insert) |
| 4 | 6 | discuss-design | code_search.ex:821 | single mailbox serializes all queries + close; a raising query crashes the shared Server (also flagged by codex; observed by 178d7539) | not applied — accepted per task 308 AC |
| 5 | 4 | discuss-trivial | code_search.ex:245 | `rebuild_index` closes only the exact resource key before deleting DB files (codex) | not applied — single-resource-per-path in practice; narrowed by finding 2 |
| 6 | 4 | extraction | code_search.ex:766 | `Harness.CodeSearch.Server` GenServer embedded in a ~1k-line file (codex) | not applied — large mechanical relocation orthogonal to correctness |
| 7 | 3 | bug | code_search.ex (definition_kind/1) | `Map.fetch!` raises on an unknown definition kind → crashes the shared Server | not applied — deliberate fail-loud on a known exograph enum |

## Auto-applied fixes

- code_search.ex:838 — `handle_call({:with_index})` restructured: a `with` rebinding of `state` inside the clause list is invisible to the `else` block, so the prior code replied in `else` with the pre-`resource_for` `state`, dropping the just-started QuackDB server + repo (linked but unreferenced; they accumulate, each holding a TCP port, under repeated index-open failures). Now `with_cached_index` runs inside the `do` block via a `case`, and the resource is persisted (index stays `nil`) on both success and index-open failure, so close_all/terminate can reclaim it and the next query retries the open.
- code_search.ex:1003 — `resource_key/2` extended with `opts[:exograph_module]` and `opts[:prefix]`, the two opts that determine the opened index/repo; without them a cached resource could be reused for a query context expecting a different table prefix or exograph module against the same index_path.
- code_search.ex:480/508 — `source_cache_insert`/`definition_cache_insert` `match_delete` prior-mtime entries (source: per repo; definition: per `{repo, prefix, limit}`) before inserting, so the ETS tables hold one live snapshot per key instead of growing unbounded across source changes on a long-lived node. Only the newest-mtime snapshot is ever looked up.

Verification: `mix test.json test/harness/code_search_test.exs` → 10/10 pass; `mix dialyzer.json` → 0 warnings. MEDIUM-tier self-grade (dashboard/agent infrastructure, not the run-lifecycle/evaluator/security path): mechanical stack green + own code-review re-read of each fix. `.sobelow-skips` regenerated for the shifted line fingerprints (all confirmed-FP per 178d7539's triage; `mix sobelow --skip` clean).

## Discuss-tier resolutions

- Finding 4 (single-mailbox serialization + crash blast-radius): not a defect — task 308's acceptance criteria explicitly chose "the GenServer mailbox is a natural serialization point" for the not-concurrently-safe DuckDB connection. 178d7539 already recorded the crash-drops-all-resources consequence as a bounded, cold-path, rebuildable tradeoff. No code change.
- Findings 5/6/7: verified Codex-only / Claude-only reads with rationale-to-not-apply recorded above; none are active bugs on the real (default-opts) caller path.

## Codex second-opinion

Status: dual-reviewer (task-mqgdzibx-v40crv; ran static-read evidence only — its sandbox couldn't resolve hex deps to run mix checks)
Corroborated findings: 3 (ETS cache leak — Claude+Codex)
Codex-only findings (verified, applied): 2 (resource_key omits prefix/exograph_module)
Codex-only findings (verified, not applied with rationale): 4, 5, 6
