---
sha: 60a4dd022a7fcc8ed13cbe737246ebc7b09de7b8
audited_at: 2026-09-20
auditor_model: gpt-6-astra
verdict: findings-applied
codex_status: dual-reviewer
---

# Run Insights architect review — task 445

Reviewed the integrated observer, evidence retrieval, publication, scheduling,
settings and dashboard against tasks 443/445. An independent static reviewer
also inspected the runtime changes and the audit fixes.

## Findings applied

- An enabled observer could not be paused after its agent/model became
  unavailable. Preserve the existing selection when disabling; enabling or
  changing the selection still requires validation. The new context regression
  failed with `:model_unavailable` before the fix; context and LiveView tests pass
  afterwards.
- Four macro-generated Postgres contract tests lacked their integration tag and
  ran in the offline suite. Pass explicit tags into the contract macro. Register
  cleanup before setup mutates application state, so a database setup failure
  cannot leave later memory tests pointed at a stopped Repo.

## Evidence

Durable results: `docs/verification/run-insights/task-445/architect.json`.
Focused offline tests: 38 passed, 17 integration tests excluded, zero failures.
Postgres: 11 database tests passed. The real Codex observation test failed inside
the local process sandbox; the same test passed outside it, publishing and then
revising a persisted finding. No production observer settings were changed.
`mix check.dispatch` and `git diff --check` passed after the audit fixes.

The full landed-base gate completed with 2,421 passed, 28 failed and 112 excluded,
83.99% coverage, before these audit fixes. It is **not green**. The test-stage
failure prevented clone, architecture and Dialyzer stages from running. Original
log: `/tmp/insights-445-architect-full.log`. Failed-test-only triage is separate;
focused passing results do not turn the full gate green.

The original task-443 evidence/memory/truncation defects are covered by maintained
memory and Postgres contracts. Inspection confirms AI-directed retrieval, complete
record snapshots, full-content change hashes, publication-only checkpoints,
attempt-based cadence and abandoned-pass reconciliation. No further runtime
defect was verified by the two reviewers.

## Visual and execution limits

Personally inspected the delivered desktop overview/settings and mobile populated
history screenshots: controls are styled, settings labelled and grouped, metadata
secondary, long history readable and excerpts collapsible. The independent Harness
reviewer rendered desktop/mobile states and exercised keyboard controls. The
live server browser was still showing the older UI when first checked; screenshots
alone do not establish which version is loaded on that server.

The Codex invocation explicitly requests a read-only sandbox with shell, hooks,
apps, skills, multi-agent, web and inherited MCP configuration disabled. Its live
boundary test proves unchanged files after a write-request prompt and real model
rejection. The output contains no actual denied-write tool event, so the agent's
prose is not independent proof of an attempted syscall denial. No bypass was found.

Installed canonical driver documentation was synchronized. No new roadmap task
was filed for these bounded audit corrections; task history remains unchanged.
