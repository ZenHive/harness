---
sha: 826aaff3b0687338ca1973a34e9ff6ff5839695b
short_sha: 826aaff
audited_at: 2026-05-23
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: harness-owned rule set injected into every adapter (Task 22)

**Original commit:** 826aaff — `feat: harness-owned rule set injected into every adapter (Task 22)`
**Author:** E.FU
**Files touched:** 15
**LOC:** +732 / -163

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 9   | bug | lib/harness/agent_rules.ex (write_system_prompt_file!, install_codex_rules!, install_cursor_rules!) + lib/harness/worktree.ex (commit/2 `git add -A`) | Harness-injected rule files written into the worktree get committed by `Worktree.commit/2`'s `git add -A` — turns a no-op agent run into `:committed` with harness internals as the deliverable (codex) | dropped to rmap follow-up Task 36 — design-deep fix with multiple options |
| 2 | discuss-design | abstraction | lib/harness/agent_adapter.ex (behaviour) | Rule injection hand-wired across all 5 adapters; not in behaviour callbacks or `ConformanceCase` — next adapter can omit silently (codex) | dropped to rmap follow-up Task 39 |
| 3 | 5   | doc-gap | CLAUDE.md L32 (AgentAdapter contract) | Adapter contract paragraph doesn't mention `build_command/1` now mutates worktree files for rule injection (codex) | applied (folded with Task 25 env mention into the same edit) |
| 4 | discuss-trivial | bug | lib/harness/agent_rules.ex L13 (`@raw_rules File.read!(@rules_path)`) | canonical.md is read at compile time via `__DIR__`, not from runtime priv/ — hot edits without recompile don't take effect (codex) | dropped — `@external_resource` triggers recompile on canonical.md changes; design choice favouring compile-time embed defensible |

## Auto-applied fixes

- `CLAUDE.md` § Architecture — Thin adapter pattern bullet: same combined edit as the a133e34 audit. Now explicitly notes that `build_command/1` (a) threads caller env per Task 25 and (b) delivers the harness-owned rule set per Task 22 (via system-prompt flag, ephemeral worktree file, or prompt preamble) while the callback count remains four. Pins the contract correctly post-Task-22.

## Discuss-tier resolutions

- **Finding 1 (`bug` pri 9, dropped to rmap Task 36):** Codex flagged that the harness-injected rule files written into the worktree (`.harness/agent-rules.md` for Claude, `AGENTS.md` for Codex, `.cursor/rules/harness-operational.mdc` for Cursor) get committed by `Worktree.commit/2` because it stages with `git add -A`. Claude verified by reading `lib/harness/worktree.ex:131-140` — confirmed `git add -A` followed by `git status --porcelain` empty-check. So a no-op agent run with no actual edits has rules files in the porcelain output → settles `:committed` instead of `:no_changes`, and the deliverable is the harness-owned rule files. The fix has four defensible architectural options (write outside the worktree where the adapter allows; pathspec exclusion; cleanup pre-commit; per-run `.git/info/exclude`). Claude's preference (pathspec exclusion sourced from `AgentRules`) and Codex's listed options diverge on the specific shape — the design decision belongs to the user. Filed as rmap Task 36 with all four options recorded.

- **Finding 2 (`discuss-design` Cat 4, dropped to rmap Task 39):** Codex flagged that rule injection is hand-wired into each adapter's `build_command/1` without behaviour-level enforcement — a new adapter can silently omit the injection and no test catches it. Resolution candidates (behaviour callback for rule delivery channel vs. ConformanceCase test extension) diverge in the long-term shape. Filed as rmap Task 39; companion to Task 27 (hoist universal adapter callbacks).

- **Finding 4 (`discuss-trivial`, dropped):** Compile-time `File.read!/1` with `@external_resource` is a defensible Elixir pattern — recompile triggers on canonical.md edits, so the "hot edit doesn't take effect" only bites in scenarios where the developer expects runtime reload. Codex's "discuss-trivial" rating matches the defensible-but-could-be-flagged shape; Claude agreed not to mutate.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 3 (Codex-flagged doc gap, also implicit in Claude's pass over CLAUDE.md)
Codex-only findings (filed as follow-up): 1 (rules-files-committed, pri 9 → rmap Task 36), 2 (behaviour abstraction → rmap Task 39)
Codex-only findings (discarded as over-flag): 4 (compile-time read — defensible design choice)

Verification notes: Codex's Cat 1 finding #1 was VERIFIED against the actual code (`lib/harness/worktree.ex:131-140` confirms `git add -A`). Codex's tools could not run (`:eperm` on Mix PubSub, missing Hex/SCM for `:descripex`), but the finding rests on file content alone, which Codex did read.
