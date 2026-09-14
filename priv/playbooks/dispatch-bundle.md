# Dispatch a bundle (fan out the next session of work)

**Use when:** the operator wants to clear the next session-sized chunk of a project's roadmap
unattended — multiple independent tasks dispatched concurrently, persisted and restart-resilient.

## Steps

1. **Resolve the project.** `project_registry-list`.
2. **Dispatch the first wave.** `dispatch-bundle` with `project_name`. It ingests the next
   session-sized bundle, serializes tasks whose `touches ∪ files_to_modify` overlap into later
   waves, and enqueues only the write-disjoint first wave (per-project `concurrency_cap`, Oban-
   persisted, restart-resilient). It returns the dispatched task ids, job ids and the held
   `serialized` plan. An empty bundle means nothing is pending — stop and say so.
3. **Watch origin for the landing commits** (one `task <id> -> done (shipped …)` per task on
   `origin/<target>`); `dispatch-status` / `dispatch-transcript` only to diagnose a straggler.
4. **Advance the chain.** After the wave lands, call `dispatch-bundle` again to release the next
   serialized wave.
5. **Report per task** from `dispatch-verdict_detail`: approved tasks are done (the reviewer fixed
   what it could inline); rejected tasks went back to the queue with the reviewer's report.

## Gotchas

- Intra-bundle `depends_on` edges are respected by `roadmap-ready`; write-set overlap is what
  `dispatch-bundle` serializes. Keep `touches` / `files_to_modify` accurate on the tasks —
  harness counts declared paths, it does not infer them from prose.
- `concurrency_cap` is set at registration (`dispatch-register_project` / `/harness/settings`);
  size all project queues to the host, since open-source Oban has no cross-queue global cap.
