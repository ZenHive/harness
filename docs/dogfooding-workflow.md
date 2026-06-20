# Dogfooding Workflow — Operational Runbook

> **Incubator only.** The generalizable harness workflow contract has been promoted to the global includes as `~/.claude/includes/harness-workflow.md` (source: `priv/includes/harness-workflow.md` in this repo; installed via `mix harness.install_includes`). Other repos adopt by adding `@~/.claude/includes/harness-workflow.md` to their `CLAUDE.md` (layered with `workflow-philosophy.md` etc — see the promoted include's "Relationship" table). This file retains harness-specific cutover history, the full driver-script template, batch run log, and repo-only sharp edges.

**Policy** lives in `CLAUDE.md` § "Dogfooding — harness Builds harness".
**AI driver contract** (for orchestrators): `skills/harness-driver/SKILL.md` — load this first when driving harness as the primary consumer.

This file is the **detailed operational runbook** (driver script template, verdict table, sharp edges). The skill is the terse, AI-optimized version of the current surfaces and patterns.

If you are a fresh session: read `CLAUDE.md` § Dogfooding first, then this.

## Cutover state

Dogfooding is **live**. The hand-built bootstrap:

- **Task 8** — supervised run lifecycle (`Harness.Run` gen_statem + `Harness.Run.Supervisor`).
- **Task 24** — commit the agent's work to the run branch before teardown (`:committing`
  state). Without it a verified run discarded its own deliverable.
- **Task 23** — immediate-EOF stdin for Port-spawned agents. Surfaced by the *first
  dogfood run*: `claude -p` over a raw OTP-port stdin printed `no stdin data received
  in 3s` and exited doing nothing. Every agent is now spawned through
  `/bin/sh -c 'exec "$0" "$@" </dev/null'`.
- **Verification-preset fix** (not a roadmap task — a one-line fix to
  `Harness.Verification`'s `@elixir_preset`). The grader ran `mix sobelow --exit`
  without `--skip`, so it ignored the repo's own `# sobelow_skip` annotations and
  would red *every* verdict. The preset now runs `sobelow --exit --skip`.

All `done`. From here on, **every task `rmap next` returns is a dogfood candidate** —
dispatch it through harness, do not implement it directly. Hand-build only what harness
cannot yet do for itself, and only after filing the gap via `rmap new`.

### Phase 7 exception (v0_5 milestone — shipped)

Tasks 44–51 (`%Harness.CheckStack{}` abstraction, `%Harness.Project{}` registry, Oban +
Postgres setup, `mix phx.new`-style Phoenix integration, GitHub clone-and-cache,
LiveView dashboard + embedded Oban Web, `Oban.Plugins.Cron`) were **hand-built in
Claude Code sessions, not dispatched through harness** — though five of the eight
(44, 45, 47, 49, 51) ended up driven through harness anyway because the per-task
diffs turned out to be small and self-contained after `mix phx.new` set the shape;
the three truly architectural pieces (46 Project registry, 48 Oban dispatch, 50
Phoenix LiveView dashboard) were hand-built. Rationale: (a) tasks that reshape the
Application supervision tree, dep stack, or Endpoint are the territory a headless
agent has the least leverage on; (b) the verification stack itself was being
reshaped by Task 44, so dogfooding while the grader changes shape is more friction
than signal; (c) `mix phx.new` is the canonical bootstrap and is faster to invoke
directly than to coach an agent through.

Dogfooding is the default again from here on. Treat the v0_5 pivot as the explicit
exception, not a precedent: a new phase that reshapes runtime supervision earns the
same hand-build window; a new phase that adds features on stable surfaces does not.

## The loop, end to end

```
Harness.Roadmap.ingest  ─▶  Harness.Run.Supervisor.start_run  ─▶  Harness.Run.Result
                                      │
                  dispatched ▶ running ▶ committing ▶ recovering ▶ reviewing ▶ done | failed
```

One run = one `Harness.Run` gen_statem. It carves a git worktree off the target repo's
`HEAD`, dispatches a headless implementer agent into it, commits the agent's diff to branch
`harness/<run-id>`, then dispatches a **cross-family reviewer AI** into the same worktree. The
reviewer reviews against the acceptance criteria, runs the project's checks itself, fixes what
it can inline, and writes `.harness/review.json`. Approve ⇒ `:done`; reject/missing ⇒ `:failed`.
The **reviewer AI is the gate** — never the implementer's self-reported result.

## Running a dogfood task

There are three dispatch paths. **The native flat MCP tools (`dispatch__task` + the
`dispatch__*` observe/triage family) are the default** — one JSON call, no struct
threading, and `dispatch__verdict_detail` reads the reviewer's verdict / report / ratings
straight from the persisted record. The **Tidewave `project_eval` path** is the escape hatch for
struct-level control the flat tools don't expose (explicit `retry_policy`, fail-over
adapter lists, `subscriber: self()`). The **`mix run` script** is the last-resort
fallback for dumping full diagnostics to your terminal in one blocking process.

> **⚠ Never start a second driver BEAM while runs are in flight.** A second harness BEAM
> starting while the first still has runs in flight runs a worktree sweep at boot that
> can prune a live sibling worktree out from under its running adapter (Task 61, open).
> Drive everything from one long-lived node — the `iex -S mix` you started for the
> dashboard. This applies to both paths below.

> **⚠ Never hot-reload/recompile the driver BEAM while runs are in flight.** A
> `mix compile` or live code reload that lands while a run's gen_statem is mid-callback
> can hit `:undef` on state functions — classic BEAM mid-purge behavior, not a missing
> clause. Prior runs through `:reviewing` on the same code prove the path exists; the
> crash is operational timing. If it happens, recover via `dispatch-rereview` on the
> retained `harness/<run-id>` branch (Task 299: harness persists a crash record and
> keeps the task `in_progress` instead of silently resetting to `pending`).

### Renderable vs executable agents

`rmap delegate --to` renders a native prompt for all six harness adapters (`:claude`, `:codex`,
`:cursor`, `:grok`, `:antigravity`, `:pi`), so each is a valid `ingest(agent: …)` value and runs
directly on its own adapter module — no claude-rendered two-step. `rmap` can also render `droid`,
but harness has no Droid adapter, so `ingest(agent: :droid)` is rejected (`{:invalid_agent, :droid}`)
and flat dispatch rejects it as `{:unknown_adapter, "droid"}`. Adding an executor is two-sided:
an rmap-lib `--to` target (already shipped for `droid`) plus a harness `AgentAdapter`.

> **Antigravity isolation note (Task 198):** `agy` ignores Port `cwd` for file writes (Task 32). Harness pins the run worktree via `--add-dir <cwd>` in `build_command/1` (Task 198 — mirrors Codex `exec --cd`, Task 41). `worktree_isolation: true` remains declared; do not re-enable autonomous `agy` dispatch until a live run proves isolation end-to-end.

### Live-node dispatch via Tidewave `project_eval` (escape hatch — struct-level control)

Reach for this only when you need struct-level control the flat `dispatch__*` tools don't
expose (explicit `retry_policy`, an ordered fail-over adapter list, `required_capabilities`,
`subscriber: self()`). For a routine dispatch, prefer `dispatch__task` below — it collapses
this whole two-eval dance into one call.

The dashboard endpoint runs the Tidewave plug in `:dev` (`Harness.Dashboard.Endpoint`,
port 4018), so any IEx-style snippet you'd run inside the orchestrator's BEAM can be sent
via `mcp__tidewave__project_eval` against the live node. The Run process records a
`%Harness.Run.LogRecord{}` to `Harness.ResultStore` on settle regardless of subscriber
state — so the eval process exiting between dispatch and observation is fine.

1. **Pick the task:** `rmap next`. Note the id.
2. **Pre-flight:** `git status` clean — the run forks a worktree off `HEAD`, so every fix
   the run depends on must already be committed.
3. **Claim it:** `rmap status <id> in_progress`. *(Only the direct `start_run` paths —
   this `project_eval` snippet and the `mix run` fallback — need this manual claim. The
   Oban dispatch path (`dispatch__task` / `Batch.dispatch`) claims it automatically on
   run start via `Harness.Run.Worker`, Task 131 — see below.)*
4. **Dispatch eval** (single `project_eval` — eval process exits immediately, that's fine):

   ```elixir
   {:ok, project} = Harness.ProjectRegistry.lookup("harness")
   {:ok, item}    = Harness.Roadmap.ingest({:id, "<task-id>"}, project: project)

   {:ok, run_id, _pid} =
     Harness.Run.Supervisor.start_run(
       item, project, Harness.AgentAdapter.Claude,
       subscriber: nil,                              # eval exits — no live subscriber
       lifetime_timeout: 3_600_000,
       env: %{"ANTHROPIC_API_KEY" => false}          # scrub: force subscription OAuth
     )

   run_id
   ```

5. **Watch live:** open `http://localhost:4018/harness/runs/<run_id>` in a browser. The
   dashboard subscribes to `Phoenix.PubSub` topic `harness:run:<id>:transcript`, which
   `AgentAdapter.Driver.run/3` feeds via its `:on_output` callback. Bounded 200 KiB buffer.

6. **Poll status (optional, while alive):** `Harness.Run.status/1` here, or the JSON-native
   `dispatch__status` / `dispatch__transcript` / `dispatch__transcript_events` tools by `run_id`
   from any MCP caller (and `dispatch__cancel` to kill it).

   ```elixir
   Harness.Run.status("<run-id>")
   #=> {:ok, %{state: :running, agent_os_pid: 12345, review_verdict: nil}}
   #=> {:ok, %{state: :done, ...}}                    # +5s linger, then process exits
   #=> {:error, :not_found}                           # after linger
   ```

7. **Observe after settle** (durable — the Run process has persisted before exiting):

   ```elixir
   {:ok, [%Harness.Run.LogRecord{} = rec]} =
     Harness.ResultStore.list_run_records(run_id: "<run-id>")

   rec.state              # :done | :failed
   rec.reason             # :approved | {:review_rejected, _} | {:review_stuck, _} | ...
   rec.verdict            # :approve | :reject | nil  (the reviewer's decision)
   rec.review_report      # the reviewer's prose report
   rec.review_ratings     # the reviewer's KPI ratings map (performance/truthfulness/…)
   rec.reviewer_diff_size # changed lines the reviewer had to fix (0 = first-attempt pass)
   rec.agent_output       # full implementer transcript (binary)
   ```

   See § Reading the verdict for what the state/reason combinations mean and what action
   each one warrants.

> **LogRecord field coverage.** `%LogRecord{}` carries the reviewer's **verdict**
> (`:approve`/`:reject`), its **report** + **ratings**, the **reviewer fix-diff size**, the full
> implementer transcript, and token usage. To triage a rejected run, call
> `dispatch__verdict_detail(run_id)` or read `rec.review_report` directly — the report is the
> reviewer's prose on what it found and why it rejected. There is no per-check stdout to dig
> through: the reviewer already ran the checks and judged them.

8. **Read the verdict** (see § Reading the verdict).

### Native MCP dispatch via `dispatch__task` (default / primary path)

The same `:4018` Bandit serves the harness **MCP server** at `/harness/mcp`. When the
harness checkout's `.mcp.json` carries a `harness` entry
(`{"type":"http","url":"http://localhost:4018/harness/mcp"}` alongside the `tidewave`
entry), the flat tools surface in-session as `mcp__harness__dispatch__task` and the rest of
the `dispatch__*` / `roadmap__*` family. This is the **default dispatch surface** — it
collapses the struct-passing `roadmap__ingest` → `supervisor__start_run` two-step (which a
JSON caller can't run: it can't hold the `%Roadmap.Item{}` / `%Project{}` between calls)
into one scalar call, and the matching `dispatch__status` / `dispatch__transcript` /
`dispatch__verdict_detail` tools cover observe + triage without ever dropping to Elixir.

Use the `project_eval` path above only for struct-level control the flat tools don't expose.

```
mcp__harness__dispatch__task(
  project_name: "harness",
  task: "<task-id>",            # or "next"
  adapter: "claude",           # codex | cursor | grok | antigravity | pi
  scrub_anthropic_key: true    # default true — strips ANTHROPIC_API_KEY → subscription OAuth
)
#=> {:ok, %{run_id: "run-..."}}
```

`scrub_anthropic_key: true` (the default) handles the OAuth-vs-API gotcha natively — no
explicit `env:` map needed. All six shipped adapters (`claude`/`codex`/`cursor`/`grok`/
`antigravity`/`pi`) ingest and dispatch directly on their own adapter module.
The run starts with `subscriber: nil`; observe it afterward by `run_id`.

> **Task-status writeback is automatic on this path (Task 131).** `Harness.Run.Worker`
> (the Oban worker behind `dispatch__task` / `Batch.dispatch`) claims the task
> `in_progress` on run start — best-effort: a failed `rmap` writeback logs and continues,
> never fails the run — so the next cron tick's `rmap ready`/`next` no longer return it.
> An **approved-but-unlanded** run (under `landing_policy: :manual`, which the harness
> self-project uses) *leaves* the task `in_progress`; only an explicit land moves it to
> `done`. This is exactly what stops the "completed re-dispatched every tick" loop.
> A **terminal-failure** run reverts the task to `pending` (`Roadmap.mark_pending/2`, not
> `blocked`) so a later tick retries; transient failures snooze without reverting. The
> direct `start_run` paths above do NOT go through the Worker, so they don't auto-claim —
> hence the manual "Claim it" step there.

**Gotchas when observing an MCP-dispatched run** (learned 2026-05-30, batch 98/103/20):

- **Observe over JSON with the flat run tools, not the store filter.** While the run is
  live, call `dispatch__status` / `dispatch__transcript` (by `run_id`); after it settles,
  `dispatch__verdict_detail(run_id)` returns the reviewer's verdict / report / ratings straight
  from the persisted record. These are the JSON-native path and avoid the filter quirk below.
- **`result_store__list_run_records` rejects a map filter.** The function wants a
  *keyword list* (`list_run_records(run_id: id)`); the MCP tool serializes `{run_id: ...}`
  as a map and fails with `no function clause matching`. Prefer `dispatch__status` /
  `dispatch__verdict_detail` (above); if you must hit the store, observe via
  `mcp__tidewave__project_eval` calling `Harness.ResultStore.list_run_records(run_id: id)`
  directly, or via `supervisor__list_runs` while the run is still registered.
- **`rec.verdict` is a plain atom** (`:approve` / `:reject`), *not* a struct — read it directly;
  the reviewer's prose lives in `rec.review_report`, the ratings in `rec.review_ratings`.
- **`agent_diff_size` is unreliable** — it under-reported a 320-insertion diff as `3` on
  Task 103. For true diff size use `git diff --stat development...<branch>`, not the field.
- **A record file appearing under `~/.harness/results/runs/<base64url(run_id)>.term` is the
  settle signal** — arm an event-shaped `Monitor` (`until [ -f "$f" ]; do sleep 5; done`)
  on it rather than polling, which the PreToolUse hook blocks.

### Full-diagnostic dispatch via `mix run` (fallback)

Use when you want the full transcript + reviewer report dumped to your terminal in one
blocking process. The driver script blocks on a `receive` for `{:harness_run, run_id, result}`
so the full `%Harness.Run.Result{}` (implementer transcript, `review` verdict artifact,
diff sizes) is in hand on settle.

> Same 6-step intent as the Tidewave path (pick / pre-flight / claim / dispatch / watch /
> read verdict), but **dispatched from a throwaway `mix run` script** instead of a
> `project_eval`. The script template's `subscriber: self()` works because the script
> process IS the subscriber and stays alive until the run settles.

1. **Pick the task / pre-flight / claim** as above.
2. **Write** `/tmp/dogfood_task<id>.exs` from the template below — change only `task_id`.
3. **Run it backgrounded:** `mix run /tmp/dogfood_task<id>.exs`. It blocks until the run
   settles (or the lifetime budget + 5m elapses), printing a 30s status ticker and, on
   settle, the agent transcript + verdict + the tail of every failed check.
4. **Read the verdict** (see § Reading the verdict).

#### Driver script template

Save as `/tmp/dogfood_task<id>.exs`, change `task_id`, run with `mix run`:

```elixir
# Dogfood driver — dispatches one rmap task through harness itself.
# Usage: mix run /tmp/dogfood_task<id>.exs   (run backgrounded; settles in minutes)
# Canonical copy + runbook: docs/dogfooding-workflow.md
#
# To dogfood a different task, change `task_id`. Nothing else needs editing.

task_id = "12"
repo = File.cwd!()
lifetime_timeout = 3_600_000

# Build a %Harness.Project{} for the harness checkout itself. Post-v0_5,
# `Run.Supervisor.start_run/4` and `Roadmap.ingest/2` both want a Project
# struct — not a path string. `check_command` is a free-text hint handed to
# the reviewer AI — harness never executes it.
project = %Harness.Project{
  name: "harness",
  source: {:local, repo},
  check_command: "mix precommit.full",
  roadmap_path: repo
}

# The dogfood agent must authenticate as the parent session's Claude
# subscription. `claude` resolves auth from ANTHROPIC_API_KEY *before* its
# stored OAuth credentials, so an inherited key shadows the subscription — and
# if that key's account has no credit, every run dies with a billing error
# before doing any work. The run scrubs the key per-agent via the `:env` opt
# passed to `start_run` below (Task 25 — caller-controlled agent environment);
# the orchestrator BEAM's own env is left untouched. See § "nested claude".

log = fn msg -> IO.puts("[dogfood] #{DateTime.to_iso8601(DateTime.utc_now())} #{msg}") end

dump = fn label, text ->
  text = text || ""

  tail =
    if String.length(text) > 6000,
      do: "...(truncated, #{byte_size(text)} bytes total)...\n" <> String.slice(text, -6000, 6000),
      else: text

  IO.puts("\n[dogfood] ----- #{label} -----\n#{tail}\n[dogfood] ----- end #{label} -----")
end

log.("ingesting rmap task #{task_id}")

case Harness.Roadmap.ingest({:id, task_id}, project: project) do
  {:ok, item} ->
    log.("ingested ##{item.id} #{item.title} — prompt #{byte_size(item.prompt)} bytes, agent #{item.agent}")

    case Harness.Run.Supervisor.start_run(item, project, Harness.AgentAdapter.Claude,
           subscriber: self(),
           lifetime_timeout: lifetime_timeout,
           env: %{"ANTHROPIC_API_KEY" => false}
         ) do
      {:ok, run_id, pid} ->
        log.("run started #{run_id} (pid #{inspect(pid)}, lifetime budget #{div(lifetime_timeout, 60_000)}m)")
        mref = Process.monitor(pid)

        ticker =
          spawn(fn ->
            Enum.each(Stream.interval(30_000), fn _ ->
              case Harness.Run.status(run_id) do
                {:ok, s} ->
                  IO.puts(
                    "[dogfood] #{DateTime.to_iso8601(DateTime.utc_now())} ... state=#{s.state} " <>
                      "agent_os_pid=#{inspect(s.agent_os_pid)} verdict=#{inspect(s.review_verdict)}"
                  )

                {:error, :not_found} ->
                  :ok
              end
            end)
          end)

        outcome =
          receive do
            {:harness_run, ^run_id, result} -> {:settled, result}
            {:DOWN, ^mref, :process, _, reason} -> {:crashed, reason}
          after
            lifetime_timeout + 300_000 -> :script_timeout
          end

        Process.exit(ticker, :kill)

        case outcome do
          {:settled, result} ->
            IO.puts("\n[dogfood] ========== RUN SETTLED ==========")
            IO.puts("run_id:     #{result.run_id}")
            IO.puts("task_id:    #{result.task_id}")
            IO.puts("state:      #{result.state}")
            IO.puts("reason:     #{inspect(result.reason)}")
            IO.puts("worktree:   #{result.worktree_path}")

            if result.agent_outcome do
              o = result.agent_outcome
              IO.puts("agent:      kind=#{inspect(o.kind)} exit=#{inspect(o.exit_status)}")
              dump.("AGENT TRANSCRIPT (raw)", o.output)
            end

            if result.review do
              IO.puts("\nreview verdict: #{result.review.verdict}")
              IO.puts("reviewer diff:  #{inspect(result.reviewer_diff_size)} changed lines")
              IO.puts("ratings:        #{inspect(result.review.ratings)}")
              dump.("REVIEWER REPORT", result.review.report)
            end

            IO.puts("[dogfood] ========== END ==========")

          {:crashed, reason} ->
            IO.puts("\n[dogfood] !!! run process CRASHED without settling: #{inspect(reason)}")
            IO.puts("[dogfood] HARNESS BUG — file via `rmap new`, do not hand-build around it")

          :script_timeout ->
            IO.puts("\n[dogfood] !!! run never settled within budget + 5m — investigate")
        end

      {:error, reason} ->
        IO.puts("[dogfood] !!! start_run failed: #{inspect(reason)}")
        System.halt(1)
    end

  {:error, reason} ->
    IO.puts("[dogfood] !!! ingest failed: #{inspect(reason)}")
    System.halt(1)
end
```

### Reading the verdict

| `state` / `reason` | Meaning | Action |
|---|---|---|
| `:done` / `:approved` | The reviewer AI approved the work (possibly after fixing it inline — check `reviewer_diff_size`). | Deliverable is the commit(s) on `harness/<run-id>` (implementer's + any reviewer fixes). Review the diff, bring it onto `development` (or let auto-landing do it), `rmap status <id> done`, update docs. |
| `:failed` / `{:review_rejected, report}` | The reviewer found nothing salvageable (degenerate case — rejection is near-never by design). | Read `report` (the reviewer's prose). The task went back to the queue; re-dispatch — possibly with a different implementer. |
| `:failed` / `{:review_stuck, report}` | The gate could not produce a verdict: no cross-family reviewer available, reviewer crashed, or it exited without writing a readable `.harness/review.json`. | Read `report`. If no reviewer was available → environment/availability issue. If the reviewer ran but wrote nothing → inspect its transcript; re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` | Harness-side mechanical failure. | **Harness bug.** File via `rmap new`, fix harness, re-dogfood. Do not work around by hand-building. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside its run worktree into the main checkout (porcelain shown in `status`). | **Agent bug** (or wrong adapter for the agent). Harness correctly trapped it (`Harness.Worktree.Isolation`). Inspect what the agent leaked, decide whether the adapter needs `worktree_isolation: false`, and re-dispatch with a worktree-honoring adapter. NOT a harness bug — the trap fired by design. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | The post-run pollution `git status` itself errored. | Rare; usually a transient git/IO issue. Re-run; if it persists inspect the main checkout's git state and the harness log. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` and re-run, or investigate why the agent hung. |
| run process **crashed** (no settle) | gen_statem died. | **Harness bug.** File via `rmap new`. |

The deliverable branch `harness/<run-id>` survives worktree teardown on an approved run; the
worktree directory itself is *retained* on a failed run (`retain_on_failure` default) for
inspection at `result.worktree_path`. Clean up a no-longer-needed retained worktree with
`git worktree remove --force <path> && git worktree prune && git branch -D <branch>`.

## Parallel dogfooding

`Harness.Run.Supervisor` is a `DynamicSupervisor` — N runs are crash-isolated
siblings, each forking its own worktree off `HEAD`. Fan them out from one
driver BEAM: ingest + `start_run` each task with `subscriber: self()`, then
collect one `{:harness_run, run_id, result}` per run in a single receive loop.
The first parallel batch dogfooded Tasks 14, 13 and 15 (the Codex / Cursor /
Grok adapters) this way; the multi-agent batch (Tasks 9, 10, 11) drove three
*different* agents concurrently — see the run log.

**Batch as widely as the dependency graph allows.** Each rmap task is sized
for ~one session, and harness exists to fan those sessions out. The
dispatchable set is **every pending task whose `depends_on` is satisfied
(all deps `status=done`)** — pick from that set, mixing drivers across Claude
/ Codex / Cursor / Grok for multi-agent coverage. Do not refuse to batch on
"these tasks touch the same file" grounds: Round-2 batched 9 / 10 / 11 (all
touching `Harness.Run`) and integration handled it cleanly. Concurrency is
gated by `:concurrency` on a `Harness.Batch` (Task 9) when you want a cap;
the dogfood driver uses raw `start_run` calls and lets the supervisor settle
them all in parallel.

**Rotate `Grok` / `Antigravity` / `Pi` in deliberately.** They are first-class
dogfood drivers — rmap renders native prompts for them, so `ingest(agent: :grok)`
→ `start_run/4` with `Harness.AgentAdapter.Grok` is the whole flow (no two-step).
Don't silently exclude them from a batch — that's training-comfort bias, not a
real constraint. Round-1 Task 25 (Grok-driven) settled approved. Antigravity's
worktree isolation requires `--add-dir` in the adapter argv (Task 198); Port `cwd` alone is insufficient.

**The one hard limit: never batch two tasks that edit the same function.**
That's a guaranteed un-auto-mergable collision (e.g. Tasks 34 + 35 both
rewriting `Batch.fill_slots/6`). Same-file is fine — same-function is not.
Either dispatch such siblings sequentially, or fold them into one rmap task
during refinement (see `task-prioritization.md` § "Refine, Don't Duplicate").

**Sequential dispatch only across BEAM lifetimes (Task 61, open).** A second
harness BEAM starting while the first still has runs in flight runs a worktree
sweep at boot that can prune a live sibling worktree out from under its running
adapter — Wave 1 of Phase 7 surfaced this (Codex's worktree disappeared mid-run
and `agy`-style cwd-resolution put its diff into Cursor's neighbouring worktree).
Until Task 61 lands a guard on `Run.commit_worktree/2` and pins the sweeper to
not touch directories whose run is still registered, **drive all parallel batches
from one long-lived driver BEAM** — do not start a second `mix run /tmp/dogfood_taskN.exs`
while another is in flight. Re-dispatch is fine; concurrent BEAMs are not.

**Integration order.** Deliverable branches `harness/<run-id>` come back onto
`development` one at a time. Bring in the smallest / most-isolated diff first,
let the rest rebase against it, resolve any same-file merges by hand. Run the
project's own check command (`mix precommit.full`) on `development` after the
last merge — if it goes red post-merge that's an integration failure, not a
per-run failure.

**Autonomous landing (Task 100, opt-in).** A project that sets both
`landing_policy: :auto` and `target_branch` skips the manual merge above: an
approved run enqueues one job on the serialized `landing_<name>` Oban queue (limit 1),
and `Harness.Lander.land/1` rebases the branch onto `origin/<target>` (if the target
moved) in a fresh detached worktree, then **ff-pushes** the tip
(`git push origin <tip>:refs/heads/<target>`, no `--force`, **no re-verification** —
the reviewer already gated the work) and advances the rmap task
(`rmap status <id> done --verified --shipped-in <sha>`). A successful push enqueues
the post-merge audit job. The push touches `origin`, never your local checkout —
after a land, `git switch <target> && git pull`. The harness self-project stays
`:manual` (no auto-push to `origin/development`). Conflict / push-rejected outcomes
retain the branch and return a typed seam for Task 101.

## HIGH-tier audit grader dispatch (`Harness.AuditReview`)

Distinct from the roadmap-task dispatch above. The codified `staged-review:audit-review`
skill ("Stake-gated fix verification") sends HIGH-tier fixes to a *different* agent
for a second-grader read — Codex grades Claude, Claude grades Codex. The grading run
produces a one-shot *text verdict*, so it **bypasses the `Harness.Run` lifecycle
(worktree + reviewer gate) on purpose**: routing a one-shot review through the full
run lifecycle would pollute the result store with non-task runs.

`Harness.AuditReview.grade_fix/1` is the one-call wrapper. It synchronously dispatches
the opposite-agent grader via `Harness.AgentAdapter.Driver.run/3` directly, parses the
grader's raw transcript for a sentinel, and returns the verdict.

```elixir
{:ok, %{verdict: verdict, outcome: outcome, grader: grader_module}} =
  Harness.AuditReview.grade_fix(
    implementer: :claude,         # who built the fix; grader auto-derives to :codex
    sha: "abc1234",               # commit being audited
    prompt: focused_review_prompt # caller-built; MUST instruct grader to emit sentinel
  )

# verdict ∈ {:approve, :reject, :unclear}
# outcome is the full %Harness.AgentAdapter.Outcome{} (raw transcript + timeout info)
# grader_module is the adapter that ran (Harness.AgentAdapter.Codex in this example)
```

**Verdict contract.** The caller's prompt MUST instruct the grader to emit
`<<<VERDICT:APPROVE>>>` or `<<<VERDICT:REJECT>>>` on a line by itself at the end of
its response. Substring-matched across every adapter output format (stream-json,
`--json`, streaming-json, plain text); last-match-wins (handles graders that reason
through both options before committing). Absent → `:unclear`.

**Default pairing.** Auto-pairs `:claude ↔ :codex` only — those are the two adapters
`audit-review` HIGH-tier explicitly names. Other implementers (`:grok`, `:cursor`,
`:antigravity`, `:pi`) require an explicit `:grader` opt. The opt accepts either a
known-agent atom or a module implementing `Harness.AgentAdapter` (test stubs
without expanding the known-agents table).

**What the wrapper does NOT do.** The audit-review skill owns focused-review prompt
construction, `.audit/<sha>.md` write-back, and revert-on-reject. `Harness.AuditReview`
is dispatch + verdict extraction only. Multi-project sweeps and cron-driven audit
scheduling are out of scope (post-Phase-7).

## Known sharp edges

- **deps in the worktree.** A fresh git worktree has no `deps/` or `_build/` (both
  gitignored). There is no mechanical bootstrap step — the implementer and the reviewer
  each run `mix deps.get` themselves when they need to compile or test. The project's
  `check_command` hint should assume a cold worktree.
- **the reviewer runs the checks.** There is no mechanical check stack. The reviewer AI
  runs the project's own `check_command` (e.g. `mix precommit.full`), judges the output,
  and fixes what it can inline before deciding. Correct-but-not-pristine work doesn't
  fail — the reviewer fixes the nitpicks and approves (fix-and-approve is the near-absolute
  default; its fixes show up in `reviewer_diff_size`).
- **the audit witnesses a cold build after merge.** The post-merge audit worktree is
  intentionally un-warmed. The audit AI runs the clean-build/check itself and writes
  `cold_check` in `.harness/audit.json`; harness persists that reported fact but never
  runs the build or reads an exit code. Red files a blocked follow-up task and notifies;
  it never reverts, unmerges, or gates the already-landed merge.
- **cold dialyzer PLT.** `priv/plts` is gitignored, so a reviewer that runs dialyzer in
  the worktree builds a PLT from cold — the slowest part of its check run. This dominates
  review wall-clock; budget the `:lifetime_timeout` for it.
- **nested claude.** The dogfood agent is `claude -p` spawned from inside a Claude Code
  session — nesting itself is fine. Auth is **not** automatically shared, though:
  `claude` checks `ANTHROPIC_API_KEY` *before* its stored OAuth credentials, so an
  inherited key shadows the parent's subscription. The run scrubs `ANTHROPIC_API_KEY`
  per-agent via the `:env` opt to `start_run` (`env: %{"ANTHROPIC_API_KEY" => false}`)
  to force the subscription fallback — without that, a run whose key account is out
  of credit dies with a `billing_error` (HTTP 400, `"Credit balance is too low"`)
  before doing any work, producing an empty diff for the reviewer to judge.
- **timeouts.** The driver sets a 60-min `:lifetime_timeout`. Implementer + reviewer (with
  a cold PLT) can be tight; raise it if a run settles `:timed_out` mid-review.
- **run results ARE persisted (Task 19 landed).** On settle, the Run process writes a
  `%Harness.Run.LogRecord{}` to `Harness.ResultStore` (file-backed under
  `~/.harness/results/runs/`) regardless of subscriber state — so a result survives the
  run process exiting and is readable later via `dispatch__verdict_detail(run_id)` or
  `Harness.ResultStore.list_run_records(run_id: id)`. The record carries the reviewer's
  verdict / report / ratings, the reviewer fix-diff size, the implementer transcript, token
  usage, and `agent_diff_size`. The deliverable *diff* itself is not in the record — it lives
  on the `harness/<run-id>` branch (reconstructed on demand by `Harness.RunDiff`, the
  run-detail diff view).
- **parallel-session rmap mutations during a run.** A second Claude Code session running
  `rmap status` / `rmap mark` / `rmap new` against the same checkout mid-run will mutate
  `ROADMAP.md`, `roadmap/data.json`, `roadmap/tasks.toml` on the main checkout. The
  pollution guard (`Harness.Worktree.Isolation`) detects this as `:checkout_polluted`
  and aborts the run — a false-positive caused by the operator, not the agent. The
  allowlist (Task 60) deliberately does NOT cover roadmap files: a genuine agent
  mutation to them during a dogfood run IS a bug worth catching. The workflow rule:
  while a dogfood wave is in flight, do not run rmap mutations in parallel sessions
  against the same repo. Use a separate worktree (e.g. `feat/task-N-*`) or wait.

## Run log

Per-batch chronological history lives in [`dogfooding-runs.md`](dogfooding-runs.md) —
append a row there when a dogfood run settles, instead of editing this file.
