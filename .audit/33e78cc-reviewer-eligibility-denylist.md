---
sha: 33e78cc9bd07ed1e6b932bf3212407eb916fd402
short_sha: 33e78cc
audited_at: 2026-06-03
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: reviewer-eligibility denylist stopgap (exclude :pi as gate) + dogfood discoveries 180/181/182

**Original commit:** 33e78cc — `harness: reviewer-eligibility denylist stopgap (exclude :pi as gate) + dogfood discoveries 180/181/182`
**Author:** E.FU
**Files touched:** 6 (run.ex, config.exs, run_test.exs + roadmap render trio)
**LOC:** +259 / −3 (most is roadmap bookkeeping for new tasks 180/181/182, superseded 179)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6   | bug (test) | test/harness/run_test.exs:397 | async:true test mutates global `:reviewer_exclude` and restores a hardcoded `[:pi]` | Applied — capture prior value |

## Summary

The code change is sound. `reviewer_excluded?/1` is added with `@spec`, gated into `reviewer_dispatchable?/1`, and carries a `TODO(Task 182)` marker pointing at the persisted-UI successor. The config bullet documents the stopgap intent. Codex verified two non-findings:

- **Fail-open correctness:** `reviewer_excluded?/1` returns `false` on the real `AgentRegistry.agent_for_module/1` error shape (`{:error, {:unsupported_adapter, module}}`), so an unknown module is never wrongly excluded.
- **Explicit path also gated:** `explicit_reviewer_dispatchable?/1` routes known agents through `reviewer_dispatchable?/1`, so the denylist applies to both auto and explicit reviewer selection (intended).

## Auto-applied fixes

- `test/harness/run_test.exs:397` — the test sets `:reviewer_exclude` to *all* agents then restored a hardcoded `[:pi]`. In an `async: true` module this (a) discards the real prior value and (b) opens a window where a concurrent async module observing reviewer selection would see "all excluded". No other test module references reviewer selection today, so the live flake probability is near-zero, but the global mutation is fragile. Fix: capture the actual prior value (`prior_exclude = Application.get_env(:harness, :reviewer_exclude, [:pi])`) and restore that. (Full concurrent isolation would require `async: false` on the module — deferred; not currently triggered.)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (Codex flagged the async global-env mutation; Claude verified `use ExUnit.Case, async: true` at run_test.exs:2)
Codex-only findings (verified): —
Codex-only findings (discarded as over-flag): —
Note: Codex could not execute the test (`:descripex` Hex/SCM load failure in its sandbox); the finding is read-based and confirmed by Claude.
