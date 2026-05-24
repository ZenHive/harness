# Dogfooding Workflow — Operational Runbook

**Policy** lives in `CLAUDE.md` § "Dogfooding — harness Builds harness". This file is
the **how**: the concrete steps a fresh Claude Code session runs to dispatch the next
roadmap task *through harness itself* instead of hand-building it.

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

### Phase 7 exception (hand-built window, v0_5 milestone)

Tasks 44–51 (`%Harness.CheckStack{}` abstraction, `%Harness.Project{}` registry, Oban +
Postgres setup, `mix phx.new`-style Phoenix integration, GitHub clone-and-cache,
LiveView dashboard + embedded Oban Web, `Oban.Plugins.Cron`) are **hand-built in a
Claude Code session, not dispatched through harness.** Rationale lives in `CLAUDE.md`
§ Dogfooding — short version: (a) most of these change the shape of harness's own
runtime (Application supervision tree, dep stack, Endpoint), exactly the territory a
headless agent has the least leverage on; (b) the verification stack itself is being
reshaped by Task 44, so dogfooding while the grader changes shape is more friction
than signal; (c) `mix phx.new` is the canonical bootstrap and is faster to invoke
directly than to coach an agent through.

Dogfooding resumes as the default once Phase 7 lands. Treat this section as the
explicit pivot-window exception, not a precedent.

## The loop, end to end

```
Harness.Roadmap.ingest  ─▶  Harness.Run.Supervisor.start_run  ─▶  Harness.Run.Result
                                      │
                  dispatched ▶ running ▶ committing ▶ verifying ▶ done | failed
```

One run = one `Harness.Run` gen_statem. It carves a git worktree off the target repo's
`HEAD`, dispatches a headless agent into it, commits the agent's diff to branch
`harness/<run-id>`, runs the verification stack against the worktree, and settles a
verdict. Green ⇒ `:done`; anything else ⇒ `:failed`. The **verification stack is the
grader** — never the agent's self-reported result.

## Running a dogfood task

There is no CLI/MCP surface yet (that is Task 17). Drive a run from a throwaway script
via `mix run`.

1. **Pick the task:** `rmap next`. Note the id.
2. **Pre-flight:** `git status` clean — the run forks a worktree off `HEAD`, so every
   fix the run depends on must already be committed; `claude`, `rmap`, `mix` on `PATH`.
3. **Claim it:** `rmap status <id> in_progress`.
4. **Write** `/tmp/dogfood_task<id>.exs` from the template below — change only `task_id`.
5. **Run it backgrounded:** `mix run /tmp/dogfood_task<id>.exs`. It blocks until the run
   settles (or the lifetime budget + 5m elapses), printing a 30s status ticker and, on
   settle, the agent transcript + verdict + the tail of every failed check.
6. **Read the verdict** (see below).

### Non-delegatable adapters contract

Non-delegatable adapters (`Grok` and `Antigravity`) are not valid options on the ingestion surface because `rmap delegate --to` does not support them (so `ingest(agent: :grok)` and `ingest(agent: :antigravity)` are rejected). Instead, task prompts are ingested using a delegatable agent (e.g. `:claude`, `:codex`, or `:cursor`), and then the ingested `Item` is passed directly to the non-delegatable adapter's module (e.g. `Harness.AgentAdapter.Grok` or `Harness.AgentAdapter.Antigravity`) when calling `Harness.Run.Supervisor.start_run/4` in the driver script.

> ⚠️ **Antigravity caveat (Task 32):** `agy` currently ignores its Port `cwd` and writes to the main checkout rather than its run worktree, so an Antigravity dogfood run will mutate the live repo instead of its isolated worktree. Do not dogfood with `Harness.AgentAdapter.Antigravity` until Task 32 is resolved.

### Driver script template

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

case Harness.Roadmap.ingest({:id, task_id}, project_root: repo) do
  {:ok, item} ->
    log.("ingested ##{item.id} #{item.title} — prompt #{byte_size(item.prompt)} bytes, agent #{item.agent}")

    case Harness.Run.Supervisor.start_run(item, repo, Harness.AgentAdapter.Claude,
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
                      "agent_os_pid=#{inspect(s.agent_os_pid)} verdict=#{inspect(s.verdict_status)}"
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

            if result.verdict do
              IO.puts("\nverdict:    #{result.verdict.status}")

              for r <- result.verdict.results do
                IO.puts(
                  "  #{String.pad_trailing(r.name, 10)} #{String.pad_trailing(to_string(r.status), 5)} " <>
                    "kind=#{r.kind} exit=#{inspect(r.exit_status)}"
                )
              end

              for r <- result.verdict.results, r.status == :fail do
                dump.("FAILED CHECK: #{r.name}", r.output)
              end
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
| `:done` | Verification went green. | Deliverable is the commit on `harness/<run-id>`. Review its diff, bring it onto `development`, `rmap status <id> done`, update docs. |
| `:failed` / `:verification_red` | Agent's work failed ≥1 check. | **Supervised** (pre-Task-11): inspect `result.worktree_path` + failed-check output, re-dispatch. The loop working, not a harness bug. |
| `:failed` / `:no_changes` | Agent produced no diff. | Read the agent transcript to find *why*. (a) Harness never got the agent working — stdin stall, bad spawn → **harness bug**, file via `rmap new`. (b) Agent reached the API and it errored — `billing_error`, auth, rate limit → **environment**, fix it (see § "nested claude") and re-run, not a harness bug. (c) Agent ran and genuinely did nothing → re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` `{:verification_failed,_}` `{:verifier_crashed,_}` | Harness-side failure. | **Harness bug.** File via `rmap new`, fix harness, re-dogfood. Do not work around by hand-building. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` and re-run, or investigate why the agent hung. |
| run process **crashed** (no settle) | gen_statem died. | **Harness bug.** File via `rmap new`. |

The deliverable branch `harness/<run-id>` survives worktree teardown on a green run; the
worktree directory itself is *retained* on a red run (`retain_on_failure` default) for
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

**Rotate non-delegatable adapters in deliberately.** `Grok` (and `Antigravity`
once Task 32 resolves) are accepted dogfood drivers via the two-step
ingest-as-delegatable + `start_run/4` with the non-delegatable adapter module
pattern (see CLAUDE.md § "Agent Headless Entry Points"). The extra step is not
a reason to silently exclude them from a batch — that's training-comfort bias,
not a real constraint. Round-1 Task 25 (Grok-driven) settled `:passed`; the
dispatch is documented and works.

**The one hard limit: never batch two tasks that edit the same function.**
That's a guaranteed un-auto-mergable collision (e.g. Tasks 34 + 35 both
rewriting `Batch.fill_slots/6`). Same-file is fine — same-function is not.
Either dispatch such siblings sequentially, or fold them into one rmap task
during refinement (see `task-prioritization.md` § "Refine, Don't Duplicate").

**Integration order.** Deliverable branches `harness/<run-id>` come back onto
`development` one at a time. Bring in the smallest / most-isolated diff first,
let the rest rebase against it, resolve any same-file merges by hand. The
verification stack re-runs on `development` after the last merge — if it
goes red post-merge that's an integration failure, not a per-run failure.

## Known sharp edges

- **deps in the worktree.** A fresh git worktree has no `deps/` or `_build/` (both
  gitignored). Verification's `mix test.json` etc. only pass if the *agent* ran
  `mix deps.get` while working — which a competent agent does. If verification fails at
  compile for missing deps, that is a harness design gap (worktree creation should seed
  deps, or the run should `mix deps.get` before verifying) — **file it via `rmap new`**.
- **strict grader.** The verification preset is `test.json`, `dialyzer.json`,
  `credo --strict`, `doctor`, `sobelow --exit --skip`. Correct-but-not-pristine output
  (one missing `@doc`) goes red. Expect supervised re-dispatch cycles.
- **cold dialyzer PLT.** `priv/plts` is gitignored, so the worktree builds a PLT from
  cold — the slowest check. Fits the 10-min per-check timeout but dominates run time.
- **nested claude.** The dogfood agent is `claude -p` spawned from inside a Claude Code
  session — nesting itself is fine. Auth is **not** automatically shared, though:
  `claude` checks `ANTHROPIC_API_KEY` *before* its stored OAuth credentials, so an
  inherited key shadows the parent's subscription. The run scrubs `ANTHROPIC_API_KEY`
  per-agent via the `:env` opt to `start_run` (`env: %{"ANTHROPIC_API_KEY" => false}`)
  to force the subscription fallback — without that, a run whose key account is out
  of credit dies with a `billing_error` (HTTP 400, `"Credit balance is too low"`)
  before doing any work, and settles `:no_changes`.
- **timeouts.** The driver sets a 60-min `:lifetime_timeout`. Agent + cold verification
  can be tight; raise it if a run settles `:timed_out` mid-verification.
- **run results are not persisted.** A settled run delivers its `Harness.Run.Result` to
  the subscriber and then stops — nothing writes it to disk (Task 19). The dogfood
  driver prints the agent transcript + verdict; if you need them later, keep the run
  log. Re-running is the only way to recover a lost result.

## Run log

Per-batch chronological history lives in [`dogfooding-runs.md`](dogfooding-runs.md) —
append a row there when a dogfood run settles, instead of editing this file.
