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
siblings, each forking its own worktree off `HEAD`. Disjoint-file tasks dogfood
in parallel **today**, with no batch orchestrator (that is Task 9, which adds
only the concurrency *cap* — not the raw concurrency). Fan them out from one
driver BEAM: ingest + `start_run` each task with `subscriber: self()`, then
collect one `{:harness_run, run_id, result}` per run in a single receive loop.
The first parallel batch dogfooded Tasks 14, 13 and 15 (the Codex / Cursor /
Grok adapters) this way — see the run log.

**Only batch genuinely disjoint tasks.** Parallel runs never collide *in the
worktree* — but their deliverable branches all merge back onto `development`.
Batch tasks whose files are disjoint (three new adapter modules); do **not**
batch tasks that edit a shared file or the `AgentAdapter` behaviour itself.

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

| date | task | run_id | state / verdict | notes |
|------|------|--------|-----------------|-------|
| 2026-05-21 | 12 — adapter conformance suite | run-1779365396207-52a8c0d0 | `failed` / `:no_changes` | First dogfood run. `claude -p` over a raw OTP-port stdin stalled and exited with no diff — surfaced **Task 23** and a **verification-preset sobelow bug** (`--skip` missing). Both hand-fixed; re-dogfood pending a commit of those fixes. |
| 2026-05-21 | 12 — adapter conformance suite | run-1779366789040-d92ba741 | `failed` / `:no_changes` | Re-run after the Task 23 commit. Agent spawned cleanly (Task 23 fix verified — no stall) and reached the API, which rejected on `billing_error` (HTTP 400, "Credit balance is too low") — the inherited `ANTHROPIC_API_KEY` shadowed the subscription. Not a harness bug; the driver now scrubs the key. |
| 2026-05-21 | 12 — adapter conformance suite | run-1779367169148-29cf0bea | `done` / `:passed` | **First fully-green dogfood run.** Driver scrubs `ANTHROPIC_API_KEY` → subscription auth. Agent (~14 min) built `Harness.AgentAdapter.ConformanceCase` (253-line reusable suite) and ran it against the Claude adapter + `FakeAdapter`; all 5 verification checks green. Deliverable committed to branch `harness/run-1779367169148-29cf0bea`. The dogfood loop working end to end. |
| 2026-05-21 | 14 — Codex adapter | run-1779369258524-7c1a28d5 | `done` / `:passed` | **First parallel dogfood batch** — Tasks 14, 13, 15 dispatched concurrently from one driver BEAM (`/tmp/dogfood_parallel.exs`). `Harness.AgentAdapter.Codex` built against the unchanged behaviour; all 5 checks green, no abstraction leak — the contract is not Claude-shaped. Surfaced a duplication discovery (`classify_message/2` / `terminate/1` / `--model` helper copied across every adapter), filed via `rmap new`. |
| 2026-05-21 | 13 — Cursor adapter | run-1779369258533-24f56b83 | `done` / `:passed` | Parallel batch. `Harness.AgentAdapter.Cursor` (`cursor-agent -p`); all 5 checks green. Conformance suite passed unchanged. |
| 2026-05-21 | 15 — Grok adapter | run-1779369258542-cc4a6123 | `done` / `:passed` | Parallel batch. `Harness.AgentAdapter.Grok` (`grok -p`); all 5 checks green. Conformance suite passed unchanged. |
| 2026-05-21 | 9 — Batch orchestrator | run-1779373868703-29f9a9b0 | `done` / `:passed` | **First multi-agent dogfood batch** — Tasks 9, 10, 11 (the Phase 3 resilience bundle) dispatched concurrently, each driven by a *different* agent. Run 9 driven by **Codex** (`Harness.AgentAdapter.Codex` as the driver, not just the deliverable — first non-Claude driver). `Harness.Batch` + `Harness.Batch.Result`; all 5 checks green. |
| 2026-05-21 | 10 — Retry policy | run-1779373868714-f42cdd07 | `done` / `:passed` | Multi-agent batch. Driven by **Cursor** (first Cursor-as-driver run). `Harness.Run.RetryPolicy` + `Harness.Run.FailureClass`; all 5 checks green. |
| 2026-05-21 | 11 — Autonomous repair loop | run-1779373868724-a4ceeede | `done` / `:passed` | Multi-agent batch. Driven by **Claude**. `Harness.Run` repair loop + `Harness.Run.RepairPrompt`; all 5 checks green. Integrating the three branches surfaced one merge-only failure: Task 9's batch test predated the repair loop and expected a red task to settle `:verification_red` — with repair default-on it settled `:no_changes` (resume produced no fresh diff). Fixed at integration by pinning `max_repair_attempts: 0` in the batch test (orchestration is its unit under test, not repair). |
| 2026-05-22 | 25 — Caller-controlled agent env | run-1779414933111-a76314a9 | `done` / `:passed` | **Round-1 multi-agent batch — first Grok-as-driver run.** `Harness.AgentAdapter.Invocation` gains an `env` field (set + `false`-to-scrub), threaded through every adapter and the port spawn; conformance suite gains a shared injection+scrubbing test. All 5 checks green. |
| 2026-05-22 | 31 — Non-delegatable adapter contract | run-1779414933121-47e95ce3 | `failed` / `:no_changes` | **Round-1 multi-agent batch — first Antigravity-as-driver run.** `agy` ignored the Port `:cd` and edited the *main checkout* instead of its worktree → worktree clean → `:no_changes`. The agent's Task 31 work (the formalized contract) was correct; it was salvaged from the main checkout, fixed (it referenced a non-existent `Harness.Run.start_run/4`), verified green by a separate evaluator pass, and committed. agy worktree-isolation bug filed as **Task 32**. |
| 2026-05-23 | 22 — Harness-owned rule set injection | run-1779511173207-ec889d74 | `done` / `:passed` | **Round-2 parallel multi-agent batch — first Cursor-as-driver Round-2 run.** Built `Harness.AgentRules` (canonical rules sourced from `priv/agent_rules/canonical.md`) + `Harness.AgentAdapter.RulesInjection` (per-adapter injection helper); every adapter's `build_command/1` now wires the rules through its best channel (Claude `--append-system-prompt-file`; Codex/Cursor ephemeral file in worktree; Grok/Antigravity prompt-prepend). Repair loop fired once (sobelow directory-traversal findings) → 5/5 green. Closeout used `rmap status 22 done --delivered-by cursor --verified` — first dogfood close-out to exercise rmap Task 28's outcome-layer flags. |
| 2026-05-23 | 16 — Capability + availability registry | run-1779511173217-4909d4fd | `done` / `:passed` | Round-2 parallel batch, driven by **Codex**. Built `Harness.AgentRegistry` (capability declaration + availability state) + capability check in `Harness.Batch` and `Harness.Run.Supervisor`; a run requesting an unsupported capability is rejected up front, never mid-run; a quota-exhausted agent fails over to another capable adapter with headroom. Repair loop fired once (credo 120-char line-length) → 5/5 green. Closeout used `--delivered-by codex --verified`. |
