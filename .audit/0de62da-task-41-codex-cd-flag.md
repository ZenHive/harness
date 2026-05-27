---
sha: 0de62da7cd4adea105240de34560a4f7b549142e
short_sha: 0de62da
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — narrow, well-tested adapter fix)
audited_by: audit-review v1
---

# Audit: harness: codex adapter — pin worktree via --cd at the exec level (task 41)

**Original commit:** 0de62da — `harness: codex adapter — pin worktree via --cd at the exec level (task 41)`
**Author:** E.FU
**Files touched:** 2 (lib/harness/agent_adapter/codex.ex, test/harness/agent_adapter/codex_test.exs)
**LOC:** +102

## Findings

None. The diff is a targeted bug fix for Task 41 (Codex worktree-isolation regression). Key shapes:

- `build_command/1` argv now starts `["exec", "--cd", invocation.cwd] ++ resume_subcommand ++ ...` — `--cd` immediately follows `exec` and precedes the optional `resume` subcommand. Codex's clap-based CLI rejects exec-level options after a subcommand, so the ordering is load-bearing.
- `session_args/1` refactor: the prior shape returned `["exec"]` / `["exec", "resume"]` as the subcommand head; the new shape returns just the trailing `[]` / `["resume"]` so `--cd` can sit at the exec level uniformly.
- Three new tests pin the regression: `--cd` presence, `--cd`-precedes-`resume` ordering on session resume, and a parallel-batch test that builds two adapters concurrently and asserts the argvs carry distinct `--cd` paths (rules out stale captures via module attribute / ETS / process dictionary).
- Module doc captures the WHY (Codex resolves workspace via git plumbing and can follow a linked worktree's `.git` file back to the main checkout — same shape as Task 32's Antigravity bug).

Confidence-filter sweep: no triggerable bug paths found.

## Auto-applied fixes

— None needed.

## Discuss-tier resolutions

— None.

## Codex second-opinion

Status: not-dispatched. 102 LOC across one production file + one test file, with regression coverage that directly proves the bug it fixes. Codex's value-add over Claude on a fix this narrow is marginal.
