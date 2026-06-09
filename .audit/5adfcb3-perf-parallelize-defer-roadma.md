---
sha: 5adfcb375e72b10b6a172139caefe4f764b6818f
short_sha: 5adfcb3
audited_at: 2026-06-09
auditor_model: claude-opus-4-8
verdict: clean
codex_status: single-reviewer (perf-iterate pair; net effect reviewed in 65b9a10)
audited_by: audit-review v1
---

# Audit: perf(dashboard): parallelize + defer roadmap rollup off /harness mount path (task 241)

**Author:** E.FU · **Files:** live.ex, roadmap_summary.ex, +tests · **LOC:** ±86

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | (none) | — | `Task.async_stream` w/ bounded timeout; degrade-to-empty on timeout/crash | clean |

## Notes
`for_projects/1` now runs per-project `rmap list` shell-outs concurrently with `on_timeout: :kill_task`; ordered `Enum.zip` re-pairs results to projects so a timed-out read degrades to a named empty summary. Also drops a duplicate `@roadmap_tick_interval_ms` module attr. Three new tests (timeout-degrade, concurrency wall-clock, seam restore). The mount-time *deferral* half of this commit was reverted in 72edccd (it exposed a worse hang); the parallelization survives into HEAD and is exercised by 65b9a10's render-path tests. Single-reviewer (Claude) — small, well-tested perf change outside the batched Codex payload.
