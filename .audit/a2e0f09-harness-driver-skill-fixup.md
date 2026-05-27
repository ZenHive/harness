---
sha: a2e0f09e1a76ae857e35614771aef07575db804a
short_sha: a2e0f09
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (skill-doc commit; no production code)
audited_by: audit-review v1
---

# Audit: skills: harness-driver/SKILL.md — fix 8 driver-surface bugs + correct dogfooding driver template

**Original commit:** a2e0f09 — `skills: harness-driver/SKILL.md — fix 8 driver-surface bugs + correct dogfooding driver template`
**Author:** E.FU
**Files touched:** 3 (CLAUDE.md, docs/dogfooding-workflow.md, skills/harness-driver/SKILL.md)
**LOC:** +118 / -50

## Findings

None. Targeted fix-up: corrects the `225cb23` skill's contract drift against the actual driver surfaces. Specifically:

- `Roadmap.ingest/2` now shown taking a `%Harness.Project{}` (the registered struct), not a string project name.
- `Harness.dispatch` (which doesn't exist) removed; `Harness.Batch.dispatch/2` shown as the Oban-backed path with the registered `concurrency_cap` governing per-project parallelism.
- `Batch.run/4` documented with `max_concurrency` + `retry_policy` + ordered adapter list for the in-process path with explicit cap.
- Non-delegatable adapters and worktree-isolation explicitly called out as separate axes.
- `cwd` guidance for the cheap `Driver.run/3` path now distinguishes `AuditReview.grade_fix/1` (defaults to `File.cwd!/0` for read-only review) from ad-hoc probes (needs a real worktree).
- Result-field guidance corrected: `worktree_path` is on the struct; `branch` is not stored on `Result` (it's the conventional `"harness/" <> run_id` shape).

Doc-only commit; verified by spot-checking each callsite signature against the live moduledocs (`Harness.Roadmap.ingest/2`, `Harness.ProjectRegistry.lookup/1`, `Harness.Batch.dispatch/2`, `Harness.Batch.run/4`, `Harness.AgentAdapter.Driver.run/3`, `Harness.AuditReview.grade_fix/1`).

## Auto-applied fixes

— None.

## Discuss-tier resolutions

— None.

## Codex second-opinion

Status: not-dispatched. Skill-text correction commit; the load-bearing verification was that the new prose matches the actual function signatures, which is faster done locally than dispatched.
