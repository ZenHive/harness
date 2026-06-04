# Dispatch a single roadmap task

**Use when:** the operator wants one specific roadmap task (or "the next one") built by a
headless agent in an isolated worktree, then gated by a cross-family reviewer AI.

## Steps (chat / MCP orchestrator)

1. **Resolve the project.** Call `project_registry__list` to get the registered project
   names. Confirm the project the operator means is registered; if not, stop and tell them to
   register it (`config/dev.local.exs` + restart, or `project_registry__register`).

2. **Pick the task.** If the operator named an id, skip to step 3. Otherwise browse:
   - `roadmap__list` with `project_name` (optionally `status: "pending"`) to see candidates, or
   - `roadmap__next_bundle` with `project_name` to let rmap's D/B/U scoring pick the next
     session-sized bundle, then take its first task.
   Never shell `rmap` yourself — these tools run against the registered project's roadmap
   correctly (including `{:github, _}` sources); a raw shell call runs from harness's own cwd.

3. **Dispatch.** Call `dispatch__task` with:
   - `project_name` — the registered project name string,
   - `task` — the task id string (e.g. `"25"`) or `"next"`,
   - `adapter` — `claude` / `codex` / `cursor` / `grok` / `antigravity` / `pi` (defaults to `claude`),
   - `scrub_anthropic_key` — leave at its default `true` for any Claude dispatch.

   This single call ingests the task, applies the secret scrub, and starts the supervised run
   with no subscriber. It returns `{run_id: ...}`. The run keeps going after the call returns.

   **Want the verdict in-band instead of polling?** Call `dispatch__await` with the same
   arguments plus an optional `timeout_ms` (default 30 min). It blocks until the run settles and
   returns the verdict summary directly — skip steps 4–5. On timeout it returns a structured
   `:timed_out` summary carrying the `run_id` (the run is not cancelled; fall back to step 4).

4. **Observe to settle.** Poll `run__status` with the `run_id` while it is alive; once it settles
   (and the 5s linger passes) read the durable record via `result_store__list_run_records`
   (`run_id:`). For a live transcript, point the operator at `http://localhost:4018/harness/runs/<run_id>`.

5. **Report the verdict.** The gate is the cross-family reviewer's verdict, never the
   implementer's self-report. Read `state` + `reason` + `review`. `:done` / `:approved` ⇒ done
   (worktree branch `harness/<run_id>` holds the commits — the implementer's plus any reviewer
   fixes). `{:review_rejected, report}` ⇒ the reviewer found nothing salvageable; the task went
   back to the queue with the reviewer's report. `{:review_stuck, report}` ⇒ the reviewer never
   wrote a readable `.harness/review.json` — re-dispatch.

## Gotchas

- **One flat call, not the struct two-step.** `dispatch__task` replaces the old
  `roadmap__ingest` → `supervisor__start_run` flow on the JSON surface. Those struct-arg tools
  (`supervisor__start_run`, `batch__*`, `agent_evaluation__*`) are deliberately **not** on the
  chat/MCP tool list — a stateless JSON caller cannot construct or thread the `%Item{}` /
  `%Project{}` structs they take.
- **Secret scrubbing is automatic.** `scrub_anthropic_key` defaults to `true`, so Claude
  dispatches use subscription OAuth, not the metered API. You don't pass an env map.
- **All six shipped adapters** (`claude` / `codex` / `cursor` / `grok` / `antigravity` / `pi`)
  dispatch through `dispatch__task` on their own adapter module — no two-step render dance.
  (`droid` renders in rmap but has no harness adapter and is rejected at ingest.)
- `result_store` records carry the reviewer's **verdict** (`approve`/`reject`), **report**,
  **ratings**, and the reviewer's fix-diff size + transcript. The report is the reviewer's prose —
  there is no per-check stdout to dig through; the reviewer already ran the checks and judged them.

## In-process Elixir / IEx driver path (NOT the chat path)

When driving harness from IEx, tidewave, or `project_eval` (SKILL.md Context A/B), you have the
full struct API and use the two-step `roadmap__ingest` → `start_run` directly:

```elixir
{:ok, project} = Harness.ProjectRegistry.lookup("myapp")
{:ok, item}    = Harness.Roadmap.ingest({:id, "25"}, project: project)   # or :next
{:ok, run_id, _pid} =
  Harness.Run.Supervisor.start_run(item, project, Harness.AgentAdapter.Claude,
    subscriber: nil,
    env: %{"ANTHROPIC_API_KEY" => false}
  )
```

rmap renders a native prompt for all six adapters (`:claude`/`:codex`/`:cursor`/`:grok`/`:antigravity`/`:pi`),
so just `ingest(agent: <adapter>)` and dispatch the `%Item{}` to its own adapter module — no
claude-rendered two-step. This struct-passing path is for the in-process driver only, not the
stateless chat/MCP orchestrator. (`droid` is renderable by rmap but has no harness adapter, so it
is not a valid executor.)
