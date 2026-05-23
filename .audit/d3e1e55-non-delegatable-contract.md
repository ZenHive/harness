---
sha: d3e1e556a06d22ada5d101e93d30e87be4b59aef
short_sha: d3e1e55
audited_at: 2026-05-23
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: docs: formalize the non-delegatable adapter contract (Task 31)

**Original commit:** d3e1e55 — `docs: formalize the non-delegatable adapter contract (Task 31)`
**Author:** E.FU
**Files touched:** 7
**LOC:** +118 / -19

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7   | doc-gap | docs/dogfooding-workflow.md (non-delegatable section) | Section describes Grok/Antigravity dispatch with no Task 32 caveat (codex) | applied: added ⚠️ caveat block |
| 2 | 4   | doc-gap | docs/agent-cli-reference.md (Task 22 verdict) | "Grok has neither a flag nor a documented rule file → prompt-prepend is the only channel" — Antigravity is in the same boat but not mentioned (codex) | applied: extended to "Grok and Antigravity have neither..." |
| 3 | 3   | doc-gap | roadmap/tasks.toml Task 31 body L825 | References nonexistent `Harness.Run.start_run/4` (should be `Harness.Run.Supervisor.start_run/4`) (codex) | applied: fixed typo |
| 4 | 4   | doc-gap | CLAUDE.md L22 (What This Is) | "Antigravity ... in an isolated git worktree" while Task 32 known | dropped — contract is the design intent; Status section already mentions Task 32 |
| 5 | 5   | doc-gap | CLAUDE.md Status paragraph | Task 26 (Antigravity adapter) not named explicitly | dropped — the Round-1 sentence "first batch to drive Grok and Antigravity as agents" implicitly references Task 26 |
| 6 | 4   | doc-gap | docs/agent-cli-reference.md L69 | Grok approval flag mismatch (`--always-approve` doc vs `--permission-mode bypassPermissions` adapter) (codex) | dropped — reference doc is the raw CLI surface, not what harness picks; intentionally separate |

## Auto-applied fixes

- `docs/dogfooding-workflow.md`: added Task 32 caveat block to the non-delegatable adapters section warning against dogfooding Antigravity until worktree isolation is fixed.
- `docs/agent-cli-reference.md`: extended the Task 22 verdict's "prompt-prepend only" sentence to include Antigravity alongside Grok.
- `roadmap/tasks.toml` Task 31 body: replaced `Harness.Run.start_run/4` with `Harness.Run.Supervisor.start_run/4`. `rmap render` re-emits `ROADMAP.md` + `roadmap/data.json` on the next render in this same audit commit.

## Discuss-tier resolutions

- (none — no discuss-tier findings.)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1, 2, 3 (auto-applied)
Codex-only findings (verified, applied): 1, 2, 3
Codex-only findings (discarded as over-flag): 4, 5, 6 — contract-vs-current-state distinction (4), implicit-reference acceptance (5), raw-CLI-vs-harness-choice intentional separation (6).

Verification notes: Codex flagged that it could not run `mix test.json` / dialyzer / credo / reach (sandbox `:eperm`/`:descripex` issues). Claude verified findings against the committed code and surrounding doc state directly.
