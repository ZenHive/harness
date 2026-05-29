# Audit-grade a fix (cross-agent HIGH-tier review)

**Use when:** a change has landed (a commit / diff) and the operator wants an independent agent —
*not* the one that wrote it — to grade it, enforcing evaluator separation on high-stakes work.

## Steps

1. **Identify the implementer and the diff.** Know which agent produced the change (`:claude` or
   `:codex`) and the commit `sha` (or have the diff ready in a worktree).

2. **Grade with the opposite agent.** `audit_review__grade_fix` with:
   - `implementer:` — the agent that wrote the code. The grader defaults to the opposite of the
     `:claude`/`:codex` pair; for any other implementer, pass `grader:` explicitly.
   - `sha:` — the commit to review.
   - `cwd:` — **the path of the repo being reviewed.** This matters: the default is harness's own
     cwd, which is almost never the repo under review when you are driving from another project.
   - `prompt:` — instruct the grader to end with `<<<VERDICT:APPROVE>>>` or `<<<VERDICT:REJECT>>>`
     on its own line. `audit_review__extract_verdict` parses last-match-wins.
   - Optionally `model:` to pin a higher-stakes grader model.

3. **Read the verdict.** The call returns `{:ok, %{verdict:, outcome:, grader:}}` for any dispatch
   that spawned. `verdict` is `:approve` / `:reject` from the sentinel; `outcome` carries the raw
   transcript (the grader's reasoning).

4. **Report.** APPROVE ⇒ relay the grader's confirming notes. REJECT ⇒ surface the grader's
   specific objections so the implementer (or the operator) can address them. The grade is the
   grader's text verdict, deliberately bypassing the green/red verification stack — this is a
   review, not a check run.

## Gotchas

- `grade_fix` uses the cheap direct driver path (no worktree lifecycle, no verification stack) on
  purpose: routing a review through the verification stack would need a fake passthrough check and
  pollute the result store with non-task runs.
- The verdict is a *review opinion*, not a build result. Treat a cross-agent REJECT as a signal to
  investigate (per the "verify external reviews" rule), not as an automatic block.
- `audit_review__default_grader` tells you which grader will be auto-paired for a given implementer
  before you dispatch.
