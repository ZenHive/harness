# Post-merge audit: a8cffbd

Reviewed `72ed985^..a8cffbd` (watermark of the prior audit through this tip). Code-bearing landings in the range: Task 389 (`roadmap_target_branch` on the operator registration surfaces), Task 402 (ExSlop checks activated + source fixes), Task 405 (audit discovery filing stays in the worktree). Roadmap-only status/file commits were checked for context and not edited except the discovery filed below.

## Findings

1. **CHANGELOG was silent on 389, 402, and 405.** Operator-visible registration, Credo-gate, and audit-writeback changes had no Unreleased entries. Added them.

2. **`dispatch-register_project` still described Postgres persistence as opt-in.** Task 389 extended the tool and the driver-skill row, and copied the stale "Runtime-only unless `:repo_enabled`" / "does NOT survive a BEAM restart unless" framing. `:repo_enabled` defaults to `true` (bugs.md #1). Reworded the MCP description, `ProjectRegistry.register/upsert` copy, and the driver-skill row. Marked bugs.md #1 fixed.

3. **`languages` is still a typeless MCP param, so a standard client cannot register a project.** Predates this range; Task 389 extended the same tool to `/9` without closing it. Not inline-doable (descripex mapping + Manifest sweep). Filed **Task 414**. Promoted bugs.md #3 and updated the stale `/8` arity.

No dead code, debug residue, or naming break warranted a source fix. The supplied reviewer rejection concerns Task 208, which is not in this range, so there is no false-rejection finding.

## Filed

- Task 414 — Give `dispatch-register_project` a typed `languages` schema so MCP clients can send a JSON array.

This filing used `--tasks-path` against this audit worktree (the Task 405 contract). The invocation prompt still named `--roadmap-path` at the live checkout because the driving node has not picked up 405 yet.

## Verification

Cold tree: `mix deps.get` then `mix check.dispatch` passed (log `/tmp/harness-check-dispatch.LiER5l.log`). Hex reported the already-adjudicated hackney 1.25.0 advisories; dependency compilation emitted upstream warnings. Format, compile `--warnings-as-errors`, Credo, Doctor (100% docs/specs), and Sobelow completed with exit 0. Sobelow warned it cannot find a Phoenix router — expected for this app's layout.

Findings: 3. Fixed here: 2. Filed follow-up: Task 414.
