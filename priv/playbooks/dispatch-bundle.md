# Dispatch a bundle (fan out the next session of work)

**Use when:** the operator wants to clear the next session-sized chunk of a project's roadmap
unattended — multiple independent tasks dispatched concurrently, persisted and restart-resilient.

## Steps

1. **Resolve the project.** `project_registry__list`, confirm the target is registered.

2. **Fetch the bundle.** `roadmap__next_bundle` with `project_name`. It returns
   `%{bundle: meta | nil, tasks: [...]}`. A `nil` bundle means nothing is pending — stop and say so.

3. **Ingest each task.** For every task in the bundle, `roadmap__ingest` with `{:id, "<id>"}` and
   the `project_name`, collecting the `%Harness.Roadmap.Item{}` list.

4. **Fan out via Oban.** `batch__dispatch` with the project and the item list. This is
   fire-and-forget: per-project concurrency is governed by the registered `concurrency_cap`, and
   jobs survive a BEAM restart (queue rows live in Postgres). It returns the enqueued jobs.
   - When you need an explicit in-process cap instead of the persisted queue, use `batch__run`
     with `max_concurrency:`.

5. **Monitor.** Point the operator at the dashboard (`http://localhost:4018/harness` for buckets,
   `http://localhost:4018/harness/oban` for the queue). Per-run drill-down + transcript at
   `/harness/runs/<run_id>`. For structured polling, `result_store__list_run_records` as each run
   settles.

6. **Report per task.** Summarize each run's `state`/`reason`/`verdict`. Green tasks are done;
   reds need triage (read the failing-check names; the repair loop already exhausted its retries).

## Gotchas

- Bundle tasks may have intra-bundle `depends_on` edges. `next_bundle` returns the whole bundle;
  if a later task depends on an earlier one, dispatch the independent layer first and the dependent
  layer after the first lands. When in doubt, dispatch the bundle's first task as a single
  (see the dispatch-single-task playbook) and re-fetch the bundle.
- Scrub `ANTHROPIC_API_KEY` (`env: %{"ANTHROPIC_API_KEY" => false}`) on Claude dispatches.
- `batch__dispatch` does not take a concurrency keyword — it reads `project.concurrency_cap`. Set
  that at registration time, sized so all project queues sum to the laptop's capacity (open-source
  Oban has no cross-queue global cap).
