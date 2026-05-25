---
sha: 42a6c113535ebfa4f652015feb64e3c24bdff365
short_sha: 42a6c11
audited_at: 2026-05-25
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 39 Audit-surfaced: Hoist rule injection into the AgentAdapter behaviour

**Original commit:** 42a6c11 — `harness: agent delivery — task 39 Audit-surfaced: Hoist rule injection into the AgentAdapter behaviour (run run-1779629242158-2c1f5bda)`
**Author:** harness
**Files touched:** 17
**LOC:** +403 / -59

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | doc-gap | CLAUDE.md:34 | "Four callbacks ... count remains four" stale after `rule_channel/0` added (now 5); also misdescribes rule threading as inside `build_command/1` rather than via behaviour-level `attach_rules/2` | applied |
| 2 | — | discuss-trivial | lib/harness/agent_adapter.ex:197 | `attach_rules/2` idempotency: any prior `%RuleDelivery{}` skips re-attach for a different adapter. No current caller swaps adapters mid-invocation; latent only | dropped — confirmed false-positive-for-now: no caller switches adapter on a populated `%Invocation{}`; the contract is dispatch-time attach, not re-attach, so changing the idempotency gate to be adapter-keyed adds complexity for no current consumer (codex-only) |
| 3 | — | discuss-trivial | lib/harness/agent_adapter.ex:225 | `invoke/2` attaches file-backed rules before adapter-side validation; `check_permission_mode`/`resume_args` errors leave ephemeral rule files in the worktree | dropped — worktree torn down on dispatch failure (Run gen_statem fail path → supervisor cleanup), so orphans don't outlive the run; reordering would couple `invoke/2` to per-adapter validation order (codex-only) |

## Auto-applied fixes

- **CLAUDE.md:34** — Updated the architecture bullet describing `AgentAdapter` from "four callbacks ... count remains four" to "five callbacks (`capabilities/0` + `rule_channel/0` + `build_command/1` required; ...)" and rewrote the rule-set description so it correctly attributes delivery to the behaviour-level `AgentAdapter.attach_rules/2` (Task 39) dispatching on `c:rule_channel/0`, instead of `build_command/1` threading `RulesInjection` directly (the pre-Task-39 architecture).

## Discuss-tier resolutions

- (none required) Both `discuss-trivial` rows above are Codex-only findings verified in-session against the current code + run lifecycle and dropped with explicit rationale rather than queued.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: — (no Claude/Codex overlap on the same row; Codex's Pri-3 doc-gap was the only finding Claude also independently noted and is the row applied as Pri-7)
Codex-only findings (verified): 2 (idempotency contract, ephemeral file lifecycle) — both verified against code + lifecycle, dropped with rationale recorded above
Codex-only findings (discarded as over-flag): —
