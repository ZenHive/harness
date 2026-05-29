# Dogfooding Workflow — Operational Runbook

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
                  dispatched ▶ running ▶ committing ▶ verifying ▶ done | failed
```

One run = one `Harness.Run` gen_statem. It carves a git worktree off the target repo's
`HEAD`, dispatches a headless agent into it, commits the agent's diff to branch
`harness/<run-id>`, runs the verification stack against the worktree, and settles a
verdict. Green ⇒ `:done`; anything else ⇒ `:failed`. The **verification stack is the
grader** — never the agent's self-reported result.

## Running a dogfood task

There are two dispatch paths. **The live-node Tidewave path is preferred** for most runs.
The `mix run` script is the **fallback** for full diagnostic dumps — debugging a
`:verification_red` run where you need per-failed-check stdout/stderr in your terminal.

> **⚠ Never start a second driver BEAM while runs are in flight.** A second harness BEAM
> starting while the first still has runs in flight runs a worktree sweep at boot that
> can prune a live sibling worktree out from under its running adapter (Task 61, open).
> Drive everything from one long-lived node — the `iex -S mix` you started for the
> dashboard. This applies to both paths below.

### Non-delegatable adapters contract

Non-delegatable adapters (`Grok` and `Antigravity`) are not valid options on the ingestion
surface because `rmap delegate --to` does not support them (so `ingest(agent: :grok)` and
`ingest(agent: :antigravity)` are rejected). Instead, ingest with a delegatable agent
(`:claude`, `:codex`, or `:cursor`) and pass the resulting `%Harness.Roadmap.Item{}`
directly to the non-delegatable adapter's module (`Harness.AgentAdapter.Grok` /
`Harness.AgentAdapter.Antigravity` / `Harness.AgentAdapter.Pi`) when calling
`Harness.Run.Supervisor.start_run/4`. Applies to both dispatch paths.

> **Antigravity caveat (Task 32):** `agy` ignores the port `cwd` and resolves workspace via git-common-dir to the main checkout. `Harness.AgentAdapter.Antigravity` declares `worktree_isolation: false`, so `Harness.Run` rejects dispatch before spawn — Antigravity cannot drive worktree-isolated runs until the CLI gains a headless workspace constraint.

### Live-node dispatch via Tidewave `project_eval` (preferred)

The dashboard endpoint runs the Tidewave plug in `:dev` (`Harness.Dashboard.Endpoint`,
port 4018), so any IEx-style snippet you'd run inside the orchestrator's BEAM can be sent
via `mcp__tidewave__project_eval` against the live node. The Run process records a
`%Harness.Run.LogRecord{}` to `Harness.ResultStore` on settle regardless of subscriber
state — so the eval process exiting between dispatch and observation is fine.

1. **Pick the task:** `rmap next`. Note the id.
2. **Pre-flight:** `git status` clean — the run forks a worktree off `HEAD`, so every fix
   the run depends on must already be committed.
3. **Claim it:** `rmap status <id> in_progress`.
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

6. **Poll status (optional, while alive):**

   ```elixir
   Harness.Run.status("<run-id>")
   #=> {:ok, %{state: :running, agent_os_pid: 12345, verdict_status: nil}}
   #=> {:ok, %{state: :done, ...}}                    # +5s linger, then process exits
   #=> {:error, :not_found}                           # after linger
   ```

7. **Observe after settle** (durable — the Run process has persisted before exiting):

   ```elixir
   {:ok, [%Harness.Run.LogRecord{} = rec]} =
     Harness.ResultStore.list_run_records(run_id: "<run-id>")

   rec.state           # :done | :failed
   rec.reason          # nil | :verification_red | {:checkout_polluted, _} | ...
   rec.verdict         # :pass | :fail | nil  (status only — see caveat below)
   rec.agent_output    # full agent transcript (binary)
   rec.failure_cause   # %{reason, failed_checks: [%{name, kind, exit_status}]}
   ```

   See § Reading the verdict for what the state/reason combinations mean and what action
   each one warrants.

> **⚠ LogRecord field coverage.** `%LogRecord{}` carries verdict **status** (`:pass`/`:fail`)
> and **failed-check names** (name + kind + exit_status), but NOT per-check stdout/stderr.
> When you need to triage a red verdict by reading the actual check output (a credo
> finding, a failing test message, the sobelow trace), the live `%Harness.Run.Result{}`
> via subscriber is the only path — drop to the **mix-run fallback** below.

8. **Read the verdict** (see § Reading the verdict).

### Full-diagnostic dispatch via `mix run` (fallback)

Use when you need per-failed-check stdout/stderr dumped to your terminal — debugging
`:verification_red` runs is the canonical case. The driver script blocks on a `receive`
for `{:harness_run, run_id, result}` so the full `%Harness.Run.Result{}` (with
`verdict.results[].output`) is in hand on settle.

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
# struct — not a path string. (Pre-v0_5 drivers passed `File.cwd!()` and
# would now FunctionClauseError on the `%Project{} = project` guard.)
{:ok, check_stack} = Harness.CheckStack.Preset.fetch(:elixir)

project = %Harness.Project{
  name: "harness",
  source: {:local, repo},
  check_stacks: [check_stack],
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
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside its run worktree into the main checkout (porcelain shown in `status`). | **Agent bug** (or wrong adapter for the agent). Harness correctly trapped it (`Harness.Worktree.Isolation`). Inspect what the agent leaked, decide whether the adapter needs `worktree_isolation: false` (like Antigravity Task 32), and re-dispatch with a worktree-honoring adapter. NOT a harness bug — the trap fired by design. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | The post-run pollution `git status` itself errored. | Rare; usually a transient git/IO issue. Re-run; if it persists inspect the main checkout's git state and the harness log. |
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
let the rest rebase against it, resolve any same-file merges by hand. The
verification stack re-runs on `development` after the last merge — if it
goes red post-merge that's an integration failure, not a per-run failure.

## HIGH-tier audit grader dispatch (`Harness.AuditReview`)

Distinct from the roadmap-task dispatch above. The codified `staged-review:audit-review`
skill ("Stake-gated fix verification") sends HIGH-tier fixes to a *different* agent
for a second-grader read — Codex grades Claude, Claude grades Codex. The grading run
produces a *text verdict*, not a green/red verification verdict, so it **bypasses
`Harness.Run` and the verification stack on purpose**: routing through them would
require a fake passthrough check and pollute the result store with non-task runs.

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
