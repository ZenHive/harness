# A/B compare adapters on one task

**Use when:** the operator wants to evaluate two or more agents (Claude vs Codex vs Cursor, …)
on the *same* task — to compare verdict, repair effort, and diff size side by side.

## Steps

1. **Resolve the project.** `project_registry__list`, confirm the target is registered.

2. **Pick one task.** `roadmap__list` / `roadmap__next_bundle` to choose a single task id well
   suited to comparison (self-contained, clear acceptance criteria — not a sprawling refactor).

3. **Ingest it once.** `roadmap__ingest` with `{:id, "<id>"}` and the `project_name`. The same
   `%Harness.Roadmap.Item{}` is run by every adapter, so the prompt is held constant.

4. **Compare.** `agent_evaluation__compare` with the item, the project, and the adapter-module
   list (e.g. `[Harness.AgentAdapter.Claude, Harness.AgentAdapter.Codex, Harness.AgentAdapter.Cursor]`)
   and a `max_concurrency`. Each adapter runs in its own isolated worktree and is graded
   independently by the same verification stack.
   - Any of the six adapters can be in the list (`Grok`, `Antigravity`, `Pi` included) — they all
     run the single shared prompt step 3 ingested. `droid` is not an option: rmap renders it but
     harness has no Droid adapter module.

5. **Read the comparison.** The result's `entries` carry per-adapter metrics: `verdict`,
   `review_iterations`, `duration_ms`, `first_attempt_failed_check_count`, `agent_diff_size`. The
   verdict stays binary pass/fail — the extra fields are the comparison signal, not a softer grade.

6. **Report the table.** Present the entries side by side. Call out: who passed on the first
   attempt, who needed reviewer help, who produced the smallest correct diff. Recommend an adapter
   only on the evidence in the entries.

## Gotchas

- This is heavier than a single dispatch — N isolated worktrees + N full verification passes.
  Reserve it for genuine adapter-selection questions, not routine task delivery.
- Scrub `ANTHROPIC_API_KEY` for the Claude entry.
- `agent_evaluation__from_batch` builds the same comparison from an already-run pinned batch when
  you dispatched via `batch__run_pinned` rather than `compare`.
