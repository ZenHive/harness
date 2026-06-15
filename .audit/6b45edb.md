---
range_end: 6b45edb0dee57247112167e6803a22e31f112830
audited_at: 2026-06-15
auditor_model: grok
verdict: findings-applied
codex_status: not-dispatched
audited_by: harness post-merge audit
---

# Audit: 6b45edb landed range

Reviewed the landed range covering the three commits listed for this audit (chronological order from git log):

- 3fae9e9 `roadmap: task 297 -> blocked` (roadmap metadata only: tasks.toml + data.json)
- f857a49 `harness: agent delivery — task 297 Lander resolver still fails 5/5 trivial additive CHANGELOG keep-both conflicts post-293; eliminate the additive-file conflict class mechanically (run run-1781503652855-2dfd0cb1)`
- 6b45edb `roadmap: task 297 -> done (shipped f857a4977f05)` (roadmap metadata only)

**Substantive change audited:** f857a49 (lib/harness/lander.ex, lib/harness/lander/resilience.ex, test/harness/lander_test.exs, and the 2-line CHANGELOG.md entry under Fixed). Roadmap files were reviewed for context only and left untouched per operational rules.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 3 | doc-staleness | `lib/harness/lander.ex:310` (rebase_onto) and `lib/harness/lander.ex:323` (resolve_or_abort) | Comments described only the agent-resolver leg of conflict handling; did not reflect the new mechanical additive `git merge-file --union` pre-pass introduced by this delivery. | fixed (comments refreshed to describe the actual control flow: additive mechanical first, then agent for remaining/genuine conflicts; witness attachment on failures) |

## Fixed

- Refreshed the two lead-in comments for `rebase_onto/4` and `resolve_or_abort/4` (and the function-level description for the latter) to accurately document the mechanical additive-union short-circuit for configured files (default CHANGELOG.md) before falling through to the cross-family resolver agent. The behavior change and witness logic were already correct in the code and tests; the comments are now consistent with the delivered control flow and with the "mechanics in code, judgment in agents" principle stated in the task body.

## Notes

- The delivery commit itself included the required CHANGELOG.md entry under `### Fixed` for Task 297 (the mechanical lander union path + witness for retained conflicts). No additional changelog hygiene was required (contrast with the prior ebb18a8 audit which filled gaps the delivery had omitted).
- All new/edited functions in the delivery carry `@spec` (including the added private helpers `stage_changelog_base/1`, `stage_changelog_run/3`, the union/merge helpers, `resolver_witness/1` (both sites), `witness_conflict/2`, etc.). Test assertions were updated to match the new witness strings in `{:conflict, output}` and in the `conflict_retain` blocked reasons. Matches project conventions.
- New code is small, focused, allocation-light on the hot path (tmp cleanup in `after`, `Enum.reduce_while` early exit on first union failure). Uses the existing `Git.run` wrapper except for the deliberate direct `System.cmd` for `git merge-file` (appropriate; the three-blob 3-way is not a repo-mutating op).
- The witness header (`Harness resolver witness: ...`) + parser in resilience gives exactly the diagnosability the task body asked for: a `:conflict_retained` reason now tells the operator whether the resolver was never selected/spawned, ran but left markers, or a mechanical union itself failed — without having to inspect the branch or resolver transcripts.
- The wave test ("additive CHANGELOG wave lands every branch without invoking the resolver") plus the hardened conflict tests (assert witness text) provide coverage for the ACs: trivial additive class is eliminated mechanically; genuine conflicts still reach the agent; failures are witnessed and retained (recover via dispatch-reland, never auto redispatch).
- The referenced recent reviewer rejection (task 208, run-1780839809032-86dd1f20, coverage 79.47% < 80% threshold on `mix precommit.full`) is for a different task and outside this landed range (task 297 only). Noted for the reviewer-quality feedback loop; no bearing on the soundness of the landed work here. The task 297 work that landed (f857a49) looks sound and matches its acceptance criteria.
- No dead code, leftover debug, test skips, or convention violations found in the changed surfaces. No other doc gaps (agent-gate-workflow.md is high-level; the resolver prompt guidance for "keep both on additive" remains correct for the non-CHANGELOG cases that still reach the agent, e.g. same-list semantic overlaps).
- No rmap follow-up discovery was filed during this review. The delivery addressed the root cause (wrong tool for a pure mechanical union) and the secondary diagnosability gap with minimal, targeted, convention-matching code + tests. The pre-existing observation in the task body that harness itself has no `merge=union` .gitattributes for CHANGELOG.md is unchanged (and outside scope of the mechanical driver work); consumer repos can still adopt the cheap .gitattributes mitigation independently.
- Overall: clean delivery. The single hygiene item was internal comment accuracy for a newly introduced branch in the lander; fixed forward as part of the audit pass. The audit commit itself will serve as the range-end marker for the next post-merge audit.