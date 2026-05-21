---
sha: c219d4f9385e53687c2e39036cfea59f4b224dd8
short_sha: c219d4f
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: define the AgentAdapter behaviour — invocation + raw capture (Task 3)

**Original commit:** c219d4f — `feat: define the AgentAdapter behaviour — invocation + raw capture (Task 3)`
**Author:** E.FU
**Files touched:** 10
**LOC:** +543 / -13

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug | lib/harness/agent_adapter.ex (`spawn_run/5`) | Agent Port omits `:stderr_to_stdout` — agent stderr (diagnostics, auth/billing errors) is lost, not captured | Applied: added `:stderr_to_stdout` |
| 2 | 3 | doc-gap | lib/harness/agent_adapter/run.ex:18 | `os_pid` doc says "nil once the port has closed" but the field is captured once at spawn and never cleared | Applied: docstring corrected |

## Auto-applied fixes

- `lib/harness/agent_adapter.ex` — `spawn_run/5` `Port.open` now includes
  `:stderr_to_stdout`, so the agent's stderr is folded into the captured raw
  stream instead of leaking to the BEAM's own stderr. Matches the in-repo
  precedent (`Harness.Verification.run_check`'s port already does this) and the
  raw-passthrough design (the AI consumer reads interleaved output natively).
  *Trade-off recorded:* a strict JSONL parser would now see stderr lines
  interleaved with `stream-json` — acceptable, since harness explicitly does no
  output parsing. `git revert` the audit commit to undo if undesired.
- `lib/harness/agent_adapter/run.ex` — `os_pid` docstring now states it is the
  spawn-time pid, `nil` only if the port closed before the pid could be read,
  and not cleared when the agent later exits.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 2 (`os_pid` doc drift — Claude + Codex both raised it)
Codex-only findings (verified): 1 (`:stderr_to_stdout` omission — verified
  against the codebase; the verification port's use of the same option
  corroborates it as the intended capture behaviour)
Codex-only findings (discarded as over-flag):
- `agent_adapter.ex:164` missing/stale `invocation.cwd` → `:exited` exit-2
  rather than an invoke error (pri 7) — **discarded.** Not reachable in the run
  lifecycle: `Harness.Run` always creates the worktree (`dispatched` state)
  before entering `running`, so `cwd` is a freshly-created directory by
  construction. Triggering it requires calling `invoke/2` directly with a bad
  `cwd`, i.e. bypassing the harness.
- `agent_adapter.ex:58` "Deliberate deferrals lack `TODO:` prefixes"
  (`discuss`) — **discarded.** The moduledoc "Deliberate deferrals" section is
  architecture prose, not inline temporary code; one of its two items was
  already resolved in `d614c9b`. The `TODO:` mandate targets inline
  `# for now…` comments, not moduledoc design sections.
