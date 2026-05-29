# Dispatch a single roadmap task

**Use when:** the operator wants one specific roadmap task (or "the next one") built by a
headless agent in an isolated worktree, then graded by the project's own check stack.

## Steps

1. **Resolve the project.** Call `project_registry__list` to get the registered project
   names. Confirm the project the operator means is registered; if not, stop and tell them to
   register it (`config/dev.local.exs` + restart, or `project_registry__register`).

2. **Pick the task.** If the operator named an id, skip to step 3. Otherwise browse:
   - `roadmap__list` with `project_name` (optionally `status: "pending"`) to see candidates, or
   - `roadmap__next_bundle` with `project_name` to let rmap's D/B/U scoring pick the next
     session-sized bundle, then take its first task.
   Never shell `rmap` yourself — these tools run against the registered project's roadmap
   correctly (including `{:github, _}` sources); a raw shell call runs from harness's own cwd.

3. **Ingest the task.** `roadmap__ingest` with `selector` `{:id, "<id>"}` (or `:next`) and the
   `project_name`. This renders the agent prompt and returns a `%Harness.Roadmap.Item{}`.
   - For a **non-delegatable** executor (Grok / Antigravity / Pi), ingest with a delegatable
     agent (`:claude`/`:codex`/`:cursor`) — the rendered prompt is agent-agnostic — then dispatch
     the item to that adapter's module in the next step.

4. **Dispatch the verified lifecycle.** `supervisor__start_run` with the item, the project, and
   the adapter module (e.g. `Harness.AgentAdapter.Claude`).
   - **Scrub secrets:** pass `env: %{"ANTHROPIC_API_KEY" => false}` for any Claude dispatch so it
     uses the subscription OAuth path, not a metered API key.
   - **Do not block on a subscriber.** When dispatching from an ephemeral surface (MCP / chat),
     pass `subscriber: nil` and capture the returned `run_id`. The run keeps going after the call
     returns.

5. **Observe to settle.** Poll `run__status` with the `run_id` while it is alive; once it settles
   (and the 5s linger passes) read the durable record via `result_store__list_run_records`
   (`run_id:`). For a live transcript, point the operator at `http://localhost:4018/harness/runs/<run_id>`.

6. **Report the verdict.** The grade is the verification stack, never the agent's self-report.
   Read `state` + `reason` + `verdict`. Green ⇒ done (worktree branch `harness/<run_id>` holds the
   commit). Red ⇒ summarize the failing checks; the repair loop already retried up to
   `max_repair_attempts` before settling.

## Gotchas

- `result_store` records carry the verdict **status** + failed-check **names** + transcript, but
  not per-check stdout/stderr. To triage a red verdict by reading actual check output, the live
  `%Harness.Run.Result{}` (subscriber path) is the only source.
- Worktree-isolation: only Antigravity declares `worktree_isolation: false`; the dispatch guard
  refuses an isolated run on it.
