---
sha: b2e272ab993eba62879f0474b8673c55e34a0da5
short_sha: b2e272a
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — commit is itself a code-review-driven fix)
audited_by: audit-review v1
---

# Audit: harness: code-review fixes — sobelow gate + baseline alias, Pi in CLAUDE.md, worker test-seam comment

**Original commit:** b2e272a — `harness: code-review fixes — sobelow gate + baseline alias, Pi in CLAUDE.md, worker test-seam comment`
**Author:** E.FU
**Files touched:** 8 (3 lib, 2 test, README, CHANGELOG, mix.exs)
**LOC:** +181 / -24

## Findings

None substantive.

- `Run.settle/2` reorders to `build_result → persist → finish_worktree → notify_subscriber`. The previous order notified the subscriber before teardown, which let subscribers race test/driver fixture cleanup. New rationale captured in the function comment. Teardown errors are logged + swallowed so the result is still delivered.
- `Run.Worker` introduces `:roadmap_ingest` and `:run_starter` Application env seams (with explicit "Never set either in production config" warning) — a sensible test-injection pattern that avoids spinning up RunSupervisor + rmap in unit tests.
- `mix.exs`: `sobelow` → `sobelow --exit --skip` aligns the alias with the verification check stack flags (`%Check{... args: ["sobelow", "--exit", "--skip"]}` in the Elixir preset). `sobelow.baseline` alias added for the `--mark-skip-all` workflow.

## Auto-applied fixes

— None.

## Codex second-opinion

Status: not-dispatched (this commit IS a code-review-driven fix — it already had the second-pair-of-eyes signal)
