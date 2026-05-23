---
sha: 348acb1bf551bcaff1f3fe37a5fb12e1c91e339f
short_sha: 348acb1
audited_at: 2026-05-23
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: batch orchestrator, retry policy & autonomous repair loop via multi-agent dogfood (Tasks 9-11)

**Original commit:** 348acb1 — `feat: batch orchestrator, retry policy & autonomous repair loop via multi-agent dogfood (Tasks 9-11)`
**Author:** E.FU
**Files touched:** 21
**LOC:** +1378 / -75

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7   | bug | lib/harness/run.ex (`repairable?/1`) | Repair loop does not classify quota-exhaustion before resuming the agent (codex) | filed as rmap Task 37 |
| 2 | 5   | bug | lib/harness/batch.ex (`loop/5`) | Slot held until `:DOWN` linger expires; result already known via `{:harness_run, ...}` (codex) | filed as rmap Task 38 |
| 3 | 6   | doc-gap | CHANGELOG.md L122 | "injectable per run or per batch" overstates current state — Batch.run does not yet call RetryPolicy.run (Task 28 pending) (codex) | applied: soften to "available as a standalone helper; wiring it into `Harness.Batch` is pending Task 28" |
| 4 | discuss-trivial | doc-gap | lib/harness/run.ex @moduledoc | `:max_repair_attempts` default 2 ambiguous wording — "2" means 2 repair attempts on top of original (3 total) (claude) | dropped; current wording defensible |

## Auto-applied fixes

- `CHANGELOG.md`: softened the RetryPolicy bullet to acknowledge Task 28 (batch wiring) is pending — matches the actual code surface (`Harness.Batch.run/4` does not call `RetryPolicy.run/2`).

## Discuss-tier resolutions

- **Finding 1 (`bug` pri 7, dropped to rmap Task 37):** Codex flagged that `repairable?/1` ignores quota-class. Claude agrees: a quota-starved agent that emits some text before the cap fires will burn `max_repair_attempts` cycles pointlessly. The existing `:no_changes` fast-path covers the silent-quota case but not the partial-output case. Resolution depends on whether the repair loop should integrate with `FailureClass.classify/2` or grow its own quota check — that design decision belongs to the user.
- **Finding 2 (`bug` pri 5, dropped to rmap Task 38):** Codex flagged that the batch slot stays occupied until `:DOWN` linger expires (5s default). The fix is a deliberate re-think of which message settles a slot — `{:harness_run, ...}` already carries the result, `:DOWN` then handles crashes. Filed as a follow-up because it touches the existing batch test surface.
- **Finding 4 (`discuss-trivial`, dropped):** Claude noted the `:max_repair_attempts default 2` wording is ambiguous to a new reader (is "2" total attempts or 2 repairs on top?). The implementation treats it as the latter (3 total runs); the test name "the loop stops at the configured attempt cap" with `max=2` reaching `repair_attempts: 2` corroborates that read. Decided not to mutate the @moduledoc — the docstring is already qualified by the cited tests and the `0 disables the autonomous repair loop` line in `config/config.exs`.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 3 (Codex over CHANGELOG; Claude agreed)
Codex-only findings (filed as follow-up): 1 (repair-loop quota), 2 (slot linger)
Codex-only findings (discarded as over-flag): finding `lib/harness/batch.ex:103 — start_run/4 errors crash the whole batch` (Codex pri 4): this is true in principle but unreachable in this commit — `start_run/4` only fails via DynamicSupervisor's path here, which is rare. The same observation against 9b686a9b is auto-applied (different priority) as rmap Tasks 34 + 35.

Verification notes: Codex reported `mix test.json` / dialyzer / credo / reach failed to launch in its sandbox (`:eperm` on Mix's PubSub socket, missing Hex/SCM for `:descripex`). Claude verified findings against the committed code directly.
