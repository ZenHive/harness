---
sha: 65b9a1090cac505878cc3ead935a575769d81f94
short_sha: 65b9a10
audited_at: 2026-06-09
auditor_model: claude-opus-4-8
verdict: findings-recorded (no fix — intentional design tradeoff)
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: perf(dashboard): move landed reconciliation git off the /harness render path (task 244)

**Author:** E.FU · **Files:** live.ex, run_feed.ex, result_store.ex, +tests · **LOC:** ±193

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | discuss | bug (codex) | result_store.ex:425 | Local-ref-only landed detection is "as fresh as last local fetch" | Verified intentional — no fix |

## Discuss resolutions
**Finding 1 (Codex-only, verified as intentional):** Removing `refresh_remote_target` from `landed_sha_for_run` means render reads the LOCAL `origin/<target>` tracking ref only. Codex notes a staleness window if `origin/<target>` advances via an *external* pusher whose update this local repo hasn't fetched. **Verified as the documented, intentional task-244 tradeoff:** the 65b9a10 moduledoc states the lander keeps `origin/<target>` fresh via its own fetch/push, and the roadmap `shipped_in` witness is the primary landed signal (branch-reachability is the fallback for unwitnessed rows only). For runs landed by this node's lander the local ref is fresh; the residual window is a multi-writer external-push scenario. A network fetch on the (formerly per-row) read path is precisely the hang this commit removes — reintroducing it would restore the bug. Codex itself classified this "intentional perf tradeoff." No action; correctness is correctly traded for a non-blocking render.

## Notes
Clean refactor: `landed_sha/3` is now pure (roadmap witness || cache lookup); branch-reachability moves to the cold-path `branch_landed_cache/3` (local git only), refreshed on connect + roadmap tick. Witnessed rows are skipped by the builder (bounded steady-state work). Well-tested incl. a witness-short-circuit case.

## Codex second-opinion
Status: dual-reviewer. Codex confirmed no unknown-outcome fallthrough in op.ex relabelers and no mantra violation. Its only flag here is finding 1 (verified intentional). Refuted: facet map-key matching is consistent.
