---
sha: de60c9ba6d7831fd7b40c72f68a98664a1497f04
short_sha: de60c9b
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — hand-built; meta-irony of audit-review auditing AuditReview noted)
audited_by: audit-review v1
---

# Audit: harness: Task 58 — Harness.AuditReview grader dispatch wrapper

**Original commit:** de60c9b — `harness: Task 58 — Harness.AuditReview grader dispatch wrapper`
**Author:** E.FU (hand-built per dogfooding bootstrap)
**Files touched:** 8 (1 lib, 1 test, CHANGELOG, CLAUDE.md, ROADMAP.md, docs, roadmap/{tasks.toml,data.json})
**LOC:** +632 / -1

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 2 | cosmetic | lib/harness/audit_review.ex:`extract_verdict/1` | Substring match on `<<<VERDICT:APPROVE\|REJECT>>>` doesn't enforce "on a line by itself" as the moduledoc promises — a sentinel inside a code fence would false-match. The prompt is responsible per the contract, but a `^...$` anchor would catch grader misbehavior cheaply. | Noted, skip (priority < 3; prompt-controlled and last-match-wins narrows the false-positive surface significantly) |
| 2 | — | acceptance | — | `grade_fix/1` synchronous wrapper bypassing Harness.Run + verification stack, with rationale captured in moduledoc: ✅ | met |
| 3 | — | acceptance | — | `:claude ↔ :codex` auto-pair with explicit `:grader` opt override: ✅ | met |
| 4 | — | acceptance | — | Module-value `:grader` opt for test stubs (no known-agents-table expansion needed): ✅ | met |
| 5 | — | acceptance | — | Sentinel last-match-wins (handles reason-through-both graders): ✅ | met |
| 6 | — | acceptance | — | `{:ok, result}` for dispatch that spawned (incl. timeouts/mid-run errors); `{:error, _}` only for un-spawnable dispatches: ✅ | met |

Notable correct shapes:

- `default_grader/1` is public + has doctests — auto-pair mapping introspectable without dispatch.
- `:no_default_grader` returned for implementers outside `:claude|:codex` — fail-closed for `:grok/:cursor/:antigravity/:pi`, forcing explicit `:grader` opt.
- Result map's `outcome` field is the full `%Outcome{}` so the caller (audit-review skill) can inspect `outcome.kind` / `outcome.output` when verdict is `:unclear`.
- TODO marker on `@grader_pairs` correctly references the future Task 54 (cost-tier capability surface) — matches the project's TODO-discipline rule.
- Plain ASCII sentinel chosen so substring matching works across every adapter's raw transcript format (stream-json, --json, streaming-json, plain text) — rationale captured.

## Auto-applied fixes

— None (no priority-3+ findings).

## Codex second-opinion

Status: not-dispatched (user-directed tight pass). Meta-irony noted: the audit-review skill is auditing the very module (`Harness.AuditReview`) it would normally dispatch to for HIGH-tier grading. Self-audit caveat acknowledged per CLAUDE.md § Evaluator Separation; module is well-tested (`test/harness/audit_review_test.exs` exists in commit) and surfaces a small clean API.
