---
sha: a133e3498355148cc682f6cc1ce7bf1181d7c136
short_sha: a133e34
audited_at: 2026-05-23
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: caller-controlled agent environment in the AgentAdapter contract (Task 25)

**Original commit:** a133e34 — `feat: caller-controlled agent environment in the AgentAdapter contract (Task 25)`
**Author:** E.FU
**Files touched:** 16
**LOC:** +70 / -34

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5   | doc-gap | CLAUDE.md L32 (AgentAdapter contract) | Thin adapter paragraph doesn't mention env injection/scrubbing (codex) | applied (folded with rules-injection mention from 826aaff) |
| 2 | 5   | doc-gap | lib/harness/agent_adapter.ex @moduledoc example L27-28 | Example `build_command/1` drops `invocation.env`, modelling a non-conformant new adapter (codex) | applied: example now threads `Map.to_list(invocation.env)` |
| 3 | 3   | doc-gap | lib/harness/agent_adapter/invocation.ex L7 (@moduledoc summary) | `env` missing from "how to run it" summary list (only in typedoc below) (codex) | applied: added `env` to the inline list |

## Auto-applied fixes

- `CLAUDE.md` § Architecture — Thin adapter pattern bullet: expanded to call out caller-controlled env threading (Task 25) AND harness-owned rule injection (Task 22), explicitly stating the callback count remains four.
- `lib/harness/agent_adapter.ex` @moduledoc example: changed `{"my-agent", ["-p", invocation.prompt], []}` → `{"my-agent", ["-p", invocation.prompt], Map.to_list(invocation.env)}` so new adapters' starting point conforms to the env contract.
- `lib/harness/agent_adapter/invocation.ex` @moduledoc: added `env` to the inline how-to-run-it field list (`session`, `permission_mode`, `model`, `adapter_opts`, `env`).

## Discuss-tier resolutions

- (none — clean docs-only auto-apply pass.)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1, 2, 3 (Codex-only doc-gap findings, applied as low-risk mechanical fixes)
Codex-only findings (verified, applied): 1, 2, 3
Codex-only findings (discarded as over-flag): none.

Cat 1 verification: Codex confirmed `Port.open` threads `{:env, port_env(env)}` at lib/harness/agent_adapter.ex:193-200, `false` is preserved as `{key, false}` at :214-219, and all five adapters thread `Map.to_list(invocation.env)` consistently. No runtime Cat 1 findings surfaced — implementation matches the contract.

Verification notes: Codex did not run mix-tool inventory (sandbox read-only). Claude verified that the conformance suite (`test/support/agent_adapter/conformance_case.ex`) gates both injection AND scrubbing on every adapter (`{"HARNESS_TEST_SET", "injected"} in env` and `{"HARNESS_TEST_SCRUB", false} in env`).
