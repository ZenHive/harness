---
sha: b72f7e0856912c242acfa9bc64af39bb716986fc
audited_at: 2026-09-20
auditor_model: gpt-6-astra
verdict: findings-applied
codex_status: dual-reviewer
---

# Lifeline ownership after hold/resume

Task 439's age-only rescue incorrectly treated a legitimate held/resumed run as
abandoned. Manual holds suspend the lifetime timer, and resume grants another
budget; the original Oban attempt can therefore exceed the age cutoff while
its run still owns the worktree. Severity: 7/10.

The Harness-owned Lifeline plugin delegates rescue/discard mechanics to Oban's
engine with a query excluding registered local dispatch runs. Attempt timestamps
are preserved for Oban's completion fence. Missing run IDs and other workers
remain eligible; a dead run's old job becomes eligible on the next rescue tick.
Like existing boot rescue, ownership assumes one harness runtime per database.

The real PostgreSQL/plugin regression failed before the fix: a held run's row
became `available` instead of remaining `executing`. Afterwards it proves held
and resumed ownership, unchanged attempt timestamp, rescue after termination,
legacy rows, audit/landing rescue and exhausted-attempt discard.

Verification:
- Focused tests including integration: 103 passed, zero failed/skipped/excluded.
- Coverage: Harness.Oban 82.42%; new Harness.Oban.Lifeline 80%.
- Independent reviewer reran the PostgreSQL regression: one passed, no retry.
- `mix check.dispatch` and `git diff --check` passed.
- Evidence: `/tmp/harness-lifeline-before.json`, `/tmp/harness-lifeline-after.json`,
  `/tmp/harness-lifeline-independent-20260920-reviewoccupancy.json`.

The larger audit also inspected landed tasks 174, 359, 387, 431 and 433 with
independent reviewers. Static delivery ratings: 174 8/10, 359 9/10, 387 8/10,
431 8/10, 433 9/10; no additional confirmed defect after their later fixes.
Task 439 rated 6/10 before this correction. These ratings do not claim a fresh
paid-agent E2E run or a green full-suite result. No roadmap tasks were filed.

On the refreshed origin/main base including tasks 388/399, 119 focused tests
passed (including PostgreSQL and question-channel tests). The dispatch gate
and architecture gate passed. A one-line formatting defect in the newly landed
Dispatch approval facade was corrected. Telemetry was added to the explicit
Dialyzer PLT application list because the plugin calls its API directly.

Full `mix ci` on the original checkout, with normal OS process access, reported
2,538 passed, three failed, 128 excluded and 84.19% coverage. One isolated rerun
passed two failures; the ProjectCache startup-barrier test remains red (already
tracked as Task 429). The refreshed base also has two pre-existing clone-gate
findings in Dispatch/Observation and TaskBoard/Live. Full CI is not green;
focused verification does not waive these failures.

After the PLT update, Dialyzer reports no Lifeline warning. Four independent
warnings remain: TaskBoard clause coverage, two Insights MuonTrap references,
and the Run.init contract introduced with the question channel.
