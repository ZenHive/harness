---
sha: 60318549aead65144c985381977f8161234bab09
short_sha: 6031854
audited_at: 2026-06-22
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 324 Stabilize cold precommit temp-worktree spawn flake

**Original commit:** 6031854 — agent-delivered (run run-1782082825051-5ff152b4)
**Author:** harness
**Files touched:** 5 (lib/harness/agent_adapter.ex, lib/harness/run/result.ex, lib/harness/status_view.ex, + 2 tests)
**LOC:** ±99

No source PR — harness auto-land workflow (reviewer-AI-gated, no per-commit GitHub PR). Not a direct-push finding; the harness reviewer gate IS the review trail.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6   | bug      | lib/harness/agent_adapter.ex:479 | Post-spawn guard `os_pid \|\| File.dir?(cwd)` can mask a failed `:cd` — a truthy os_pid from the forked child does not prove the cd landed in a live worktree | Applied: guard is now `File.dir?(cwd)`-authoritative |
| 2 | 4   | robustness | lib/harness/status_view.ex:185 | Removing the catch-all `describe_reason(other)` made a `term()`-spec'd display formatter partial; a non-conforming (e.g. old persisted) reason now raises and crashes the status render | Applied: restored total-function `inspect` fallback + a covering test |

## Auto-applied fixes

- lib/harness/agent_adapter.ex:479 — dropped the `run.os_pid ||` branch; `File.dir?(invocation.cwd)` is now the sole authoritative post-spawn signal. Catches the temp-worktree cleanup race regardless of whether erl_child_setup left a truthy os_pid on a failed chdir. **HIGH-tier (core runtime spawn path)** — independent Codex second-grader returned APPROVE (os_pid still consumed by lifecycle callers; no false `cwd_missing` for healthy local worktrees since `File.dir?` runs microseconds after `Port.open`).
- lib/harness/status_view.ex:185 — restored `defp describe_reason(other), do: inspect(other)` so the status renderer never crashes on an unexpected reason shape.
- test/harness/status_view_test.exs — added "falls back to inspect for an unrecognized reason shape" test for the restored branch.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (Codex priority 8), 2 (Codex priority 5) — both independently raised by Claude and Codex.
Codex-only findings (verified): none.
Codex-only findings (discarded as over-flag): none.
HIGH-tier fix grade: APPROVE (finding 1).
