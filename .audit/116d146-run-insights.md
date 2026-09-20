# Run Insights architect review

Reviewed task 443 delivery 677fb26 and reviewer correction 116d146 on integrated base 8a17f3a, 2026-09-20. Verdict: changes required. Prior Harness approval is not sufficient to establish the accepted feature contract.

## Confirmed with independent regression probes

The adjacent `116d146-run-insights-regressions.exs` contains three expected-behavior tests. Running `MIX_ENV=test mix test.json .audit/116d146-run-insights-regressions.exs --no-retry` reproduces three failures on this base. These tests are deliberately outside the normal suite; the corrective task must move them into maintained ExUnit coverage and make them pass.

1. P1: Finding memory loses relevant prior observations. `Insights.run_pass/1` supplies only one independently rotating ten-finding page, then marks evidence consumed. With eleven findings, a change to the run linked to the oldest finding is processed without that finding. The following pass sees no changed evidence and skips the AI, even though it now selects the old finding. Recurrence is missed or duplicated. Mechanical pagination must not decide what prior context the AI is allowed to consider before consuming evidence.
2. P1: Structured review concerns/checks and run failure reasons are absent from `Evidence.historical/1` and the Postgres projection. The probe supplies a unique concern marker and proves it never reaches the witness. Concern-only changes also cannot alter the selected-source fingerprint. These are direct evidence of the recurring problems this feature exists to expose.
3. P1: Evidence can be silently truncated while labelled available. `inspect(facts, limit: :infinity)` retains the default printable string limit. A 5,000-character review report loses its final finding, while the generated source is shorter than the 8,000-byte source cap and is marked available. SQL report truncation likewise needs explicit extent and change tracking. All retained evidence must truthfully describe omitted content and permit the witness to reach the needed remainder.

## Additional static findings

4. P2: Failure scheduling uses last_success only. After three failed Oban attempts, the discarded job no longer deduplicates a newly due job. The minute tick creates another retry group even with Daily selected. Preserve the successful evidence checkpoint separately from the last attempt/next scheduled attempt.
5. P2: Worker death, timeout, restart, thrown exceptions and final publication-write failure can leave a pass permanently observing. Only returned errors in the `with` clauses are persisted as failures. Reconcile actual attempt termination using mechanical job/process facts; do not classify prose.

An independent second agent confirmed findings 4 and 5 by static review. It did not execute tests or mutate code.

## Product acceptance gaps

6. The observer is hard-coded to Claude/sonnet and rejects Codex. The operator explicitly requires Codex; the accepted agent/model selection was not permission to restrict the feature to Claude. Support explicit Codex selection with a verified observation-only execution boundary and model selection from the configured catalog, without provider fallback.
7. Browser inspection of `/harness/insights` and `/harness/insights/settings` confirms raw browser-default buttons/selects, adjacent controls without spacing, an inline ungrouped settings form and a generic empty-result sentence instead of a useful paused onboarding state. Match the existing dashboard typography, tokens, panels and buttons. Verify desktop/mobile, populated findings/history, settings and errors visually, not just HTTP 200 or matching text.

## Verification status

- Three custom regression probes: 0 passed, 3 failed as described above. JSON evidence: /tmp/insights-architect-review.json on the reviewing host.
- Production overview and settings inspected in a real browser; observer remained disabled and no settings were changed.
- Original run record: implementer codex/gpt-6-astra; reviewer Cursor/cursor-grok-4.6-xhigh. Sonnet is the observer default, not that reviewer.
- `mix precommit.full` stops at the pre-existing descripex `~> 1.0.0` dependency policy violation. Remaining `mix precommit` was run separately; this does not turn the full gate green. No full-suite success claim is made here.
- Corrective work must preserve task 443's delivery history and record a new convergence task, per the orchestrator contract.
