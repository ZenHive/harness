# A/B compare adapters on one task

**Use when:** the operator wants to evaluate two or more agents (Codex vs Cursor vs Grok, …)
on the *same* task — to compare reviewer verdicts, fix effort, and diff size side by side.

## Steps

1. **Resolve the project.** `project_registry-list`, confirm the target is registered.

2. **Pick one task.** `roadmap-list` / `roadmap-next_bundle` to choose a single task id well
   suited to comparison (self-contained, clear acceptance criteria — not a sprawling refactor).

3. **Compare.** `dispatch-compare` with `project_name`, the task id, and the adapter list (e.g.
   `["codex", "cursor", "grok"]`; optional per-adapter model overrides). The task is ingested
   once so every adapter runs the same prompt; each runs in its own worktree and is gated
   independently by the same cross-family reviewer contract. The call blocks until every run
   settles.
4. **Read the comparison.** `entries` carry per-adapter `verdict`, `reviewer_diff_size`,
   `duration_ms`, `agent_diff_size`, `token_usage`. The verdict stays binary; the extra fields
   are the comparison signal, not a softer grade.

5. **Report the table.** Present the entries side by side. Call out: who got approved with zero
   reviewer fixes (reviewer diff 0 = first-attempt pass), who needed reviewer help, who produced
   the smallest correct diff. Recommend an adapter only on the evidence in the entries.

## Gotchas

- N isolated worktrees + N reviewer runs — reserve it for genuine adapter-selection questions.
- Pair `cursor` and `grok` with a `codex` reviewer: they are one SpaceXAI family.
