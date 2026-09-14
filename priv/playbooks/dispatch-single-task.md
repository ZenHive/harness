# Dispatch a single roadmap task

**Use when:** the operator wants one specific roadmap task (or "the next one") built by a
headless agent in an isolated worktree, then gated by a cross-family reviewer AI.

## Steps (chat / MCP orchestrator)

1. **Resolve the project.** `project_registry-list`. If the project the operator means is not
   registered, stop and say so (`/harness/settings`, `mix harness.seed`, or
   `dispatch-register_project`).

2. **Pick the task.** If the operator named an id, skip to step 3. Otherwise
   `roadmap-list` (`project_name`, optionally `status: "pending"`) or `roadmap-next_bundle`
   and take its first task. Never shell `rmap` yourself — these tools run against the
   registered project's roadmap (including `{:github, _}` sources); a raw shell call runs from
   harness's own cwd.

3. **Dispatch.** `dispatch-task` with `project_name`, `task` (an id string such as `"25"`, or
   `"next"`), and optionally `adapter` (`recommend` — the default — honours the task's pinned
   `assignee`; `codex` / `cursor` / `grok` / `antigravity` / `pi` / `claude` bypass it). It
   returns `{run_id: …}` and the run keeps going after the call returns. Secret scrubbing is
   automatic (`scrub_anthropic_key` defaults to `true`).

4. **Wait by watching origin, not by blocking.** Under `landing_policy: :auto` the landed
   signal is the lander's `task <id> -> done (shipped …)` commit on `origin/<target>`; poll
   `dispatch-status` with the `run_id` only to diagnose a run that is not landing. Do not hold
   `dispatch-await` open for a full run — the MCP idle timeout kills the call, and it returns at
   reviewer settle, before the land.

5. **Report the verdict.** `dispatch-verdict_detail` with the `run_id`. `:done` / `:approved`
   ⇒ the reviewer approved (branch `harness/<run_id>` holds the implementer's commits plus any
   reviewer fixes). `{:review_rejected, report}` ⇒ nothing salvageable; the task is back in the
   queue with the report. `{:review_stuck, report}` ⇒ no readable `.harness/review.json`;
   recover with `dispatch-rereview` (committed work exists) rather than a fresh dispatch.

## Gotchas

- **One flat call.** `dispatch-task` is the JSON surface; the struct two-step
  (`Harness.Roadmap.ingest/2` → `Harness.Run.Supervisor.start_run/4`) exists only on the
  in-process Elixir surface (`project_eval` / IEx) because a stateless JSON caller cannot hold
  `%Item{}` / `%Project{}` between calls.
- **All six shipped adapters** dispatch through `dispatch-task` on their own adapter module.
  `droid` renders in rmap but has no harness adapter and is rejected at ingest.
- Run records carry the reviewer's verdict, report, checks, concerns, ratings and fix-diff size —
  there is no per-check stdout; the reviewer ran the checks and judged them.

## In-process Elixir / IEx driver path (NOT the chat path)

When driving harness from IEx, tidewave, or `project_eval` (SKILL.md Context A/B), you have the
full struct API and use the two-step `Harness.Roadmap.ingest/2` → `start_run` directly:

```elixir
{:ok, project} = Harness.ProjectRegistry.lookup("myapp")
{:ok, item}    = Harness.Roadmap.ingest({:id, "25"}, project: project)   # or :next
{:ok, run_id, _pid} =
  Harness.Run.Supervisor.start_run(item, project, Harness.AgentAdapter.Codex, subscriber: nil)
```

rmap renders a native prompt for all six adapters (`:claude`/`:codex`/`:cursor`/`:grok`/`:antigravity`/`:pi`),
so `ingest(agent: <adapter>)` and dispatch the `%Item{}` to its own adapter module. This
struct-passing path is for the in-process driver only, not the stateless chat/MCP orchestrator.
(`droid` is renderable by rmap but has no harness adapter, so it is not a valid executor.)
