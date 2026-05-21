---
sha: d614c9bac51930f94c637948ba2552b4dfdd8d0c
short_sha: d614c9b
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: Claude Code headless adapter + generic run driver (Task 4)

**Original commit:** d614c9b — `feat: Claude Code headless adapter + generic run driver (Task 4)`
**Author:** E.FU
**Files touched:** 19
**LOC:** +947 / -107

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug | lib/harness/agent_adapter/driver.ex (`loop/6`) | A flooding agent keeps the mailbox non-empty past `total_timeout` / `idle_timeout` — `receive` always matches a message, so the `after` clause never fires and neither deadline is enforced | Applied: pre-`receive` `wait == 0` guard |

## Auto-applied fixes

- `lib/harness/agent_adapter/driver.ex` — `loop/6` now terminates the run when
  `wait` (the nearer deadline's remaining time) is `0`, before re-entering
  `receive`. The deadline-expiry action was extracted into `expire/4` (shared by
  the guard and the `after` clause). Mirrors the same fix applied to
  `Harness.Verification.collect/5` in this audit — both receive loops shared the
  starvation gap.

## Discuss-tier resolutions

- (none — corroborated bug, mechanical fix, `discuss-trivial`)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (Codex flagged `driver.ex:91` flood-starvation at
  pri 8; Claude reached the same conclusion — Codex flagged the identical
  pattern again on `6943ca2`'s `collect/5`)
Codex-only findings (verified): —
Codex-only findings (discarded as over-flag):
- `os_process.ex:67` `kill/1` reaps only the immediate OS pid; an
  agent-spawned child survives (pri 8) — **discarded.** Deliberate,
  in-code-documented limitation: the `OSProcess` moduledoc states it and names
  `Harness.Worktree.Sweeper` as the backstop.
- `agent_adapter.ex:164` missing `cwd` → `:exited` exit-2 (pri 6) —
  **discarded.** Same as the `c219d4f` finding: not reachable in the run
  lifecycle, which always creates the worktree before spawning the agent.
- `roadmap/tasks.toml:217` Task 4 "session resume across two runs" is only
  argv-tested (pri 5) — **acknowledged, not filed.** The `--continue` resume
  mechanism is sound and unit-tested at the argv level; a live two-run resume
  integration test would strengthen coverage but the mechanism is not in doubt.
  Recorded here for the maintainer; not worth a tracked task on its own.
- `ROADMAP.md:12` focus block stale (pri 4) — **discarded.** The committed
  `ROADMAP.md` is in sync with `roadmap/tasks.toml` (`rmap validate
  --check-render` → `valid`); the focus phase is rmap-computed render output.
