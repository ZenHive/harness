---
name: harness-driver
description: >
  How an AI orchestrator (Claude Code, Cursor, Grok, etc.) uses harness as its primary
  delegation engine. The stable contract, recommended patterns, and sharp edges for
  driving verified agent work through harness instead of hand-building or raw calls.
when-to-use: "Use when you are the orchestrator and want to delegate work via harness (rmap tasks, verified runs, cross-agent grading, A/B evaluation, etc.). Read this before writing custom driver scripts."
argument-hint: "harness driver | delegate via harness | use harness for this task"
---

# Harness Driver Skill

**Purpose:** Make harness the default, reliable way an AI gets work done with verification, isolation, and restart resilience — instead of raw agent calls or hand-building.

**Primary user:** AI orchestrators (you). The human is secondary.

**Post-v0_5 reality (milestone complete):** Harness is a multi-project OTP node with Oban dispatch, per-project queues, restart resilience, Phoenix LiveView dashboard + Oban Web, and `Oban.Plugins.Cron` for autonomous polling. Dogfooding is the default again.

---

## Core Principle

**Never hand-build what harness can dispatch.**

If the task is on the roadmap and the surface is stable, dispatch it through harness (ingest → run → verified result). Hand-build only when harness genuinely cannot yet do it (rare, and only after filing via `rmap new`).

The verification stack — not the agent's self-report — is always the source of truth.

---

## Two Main Surfaces

### 1. Full Verified Lifecycle (recommended default)

Use when you want the complete harness guarantees:

- Isolated git worktree (`harness/<run-id>` branch)
- Harness-owned rule injection
- Commit of the agent's work before teardown
- Target project's own check stack as the grader
- Autonomous repair loop (red → feed failures back → re-grade, up to `max_repair_attempts`)
- Proper `Harness.Run.Result` with structured verdict

**Entry points (Elixir, callable via Tidewave `project_eval` or IEx):**

```elixir
# Fetch the registered project (a %Harness.Project{}, NOT a string).
{:ok, project} = Harness.ProjectRegistry.lookup("my_project")

# Single task (most common)
{:ok, item} = Harness.Roadmap.ingest({:id, "123"}, project: project)
{:ok, run_id, pid} = Harness.Run.Supervisor.start_run(
  item,
  project,                          # must be %Harness.Project{} — guarded
  Harness.AgentAdapter.Grok,        # or .Claude, .Codex, .Cursor, etc.
  subscriber: self(),
  lifetime_timeout: 3_600_000,
  env: %{"SOME_KEY" => false}       # scrub inherited secrets
)

# Wait for result
receive do
  {:harness_run, ^run_id, %Harness.Run.Result{} = result} -> result
end
```

`Roadmap.ingest/2` options worth knowing:
- `:project` — `%Harness.Project{}`; supplies `roadmap_path`. Use this for registered projects.
- `:project_root` — string path; fallback when `:project` is omitted. Defaults to `File.cwd!/0`.
- `:agent` — `:claude | :codex | :cursor` (the agents `rmap delegate --to` supports). Defaults to `:claude`. The ingested prompt is rendered for *this* agent — see "Non-delegatable adapters" below for what to do when the executing adapter differs.
- `:rmap_bin` — override the `rmap` binary name/path.

`Run.Supervisor.start_run/4` options worth knowing (full list in moduledoc):
- `:subscriber` — pid that receives `{:harness_run, run_id, result}`. Defaults to caller.
- `:total_timeout` / `:idle_timeout` — agent run timeouts (forwarded to `Driver`).
- `:lifetime_timeout` — whole-job wall budget in ms.
- `:adapter_opts` — per-adapter knobs forwarded to `Invocation`.
- `:required_capabilities` — gated at dispatch; the run won't start if the selected adapter lacks them.
- `:retry_policy` — `%Harness.Run.RetryPolicy{}` or keyword list; controls repair-loop quota handling.
- `:env` — `%{"KEY" => "val"}` to set, `%{"KEY" => false}` to scrub.

For Oban-backed dispatch (preferred for persistence + restart resilience):

```elixir
{:ok, jobs} = Harness.Batch.dispatch(project, [item1, item2])
```

`Batch.dispatch/2` is fire-and-forget — per-project concurrency is governed by the registered `concurrency_cap`, not a keyword. When you need an in-process batch with an explicit cap and the failure-classified retry policy, use `Batch.run/4` instead:

```elixir
{:ok, results} = Harness.Batch.run(items, project, Harness.AgentAdapter.Claude,
  max_concurrency: 3,
  required_capabilities: [...],
  retry_policy: [...]
)
```

`Batch.run/4` also accepts an ordered adapter list (quota fail-over) and a registered-project *name* in place of the struct.

**Non-delegatable adapters (`rmap delegate --to` blocklist: Grok, Antigravity, Pi):**

This is a separate axis from `worktree_isolation`. *Non-delegatable* means `ingest(agent: :grok | :antigravity | :pi)` is rejected because `rmap delegate --to` doesn't render prompts for those agents — not that they can't run worktree-isolated.

Two-step pattern (do not skip):

1. Ingest using a delegatable agent (`:claude`, `:codex`, or `:cursor`) — the rendered prompt is agent-agnostic enough to drive any executor.
2. Pass the resulting `%Harness.Roadmap.Item{}` directly to `Harness.Run.Supervisor.start_run(item, project, Harness.AgentAdapter.Grok, ...)`.

> **Worktree isolation is the other axis.** Of the six adapters, only `Harness.AgentAdapter.Antigravity` declares `worktree_isolation: false` (Task 32 — `agy` resolves workspace via git-common-dir, ignoring port `cwd`). Claude, Codex, Cursor, **Grok, and Pi** all declare `worktree_isolation: true`. The dispatch guard (`Harness.Worktree.Isolation`) refuses to start a worktree-isolated run on an adapter that declares `false`.

### 2. Cheap / Direct Driver Path (`Harness.AgentAdapter.Driver.run/3`)

Use for:
- Cross-agent grading (`Harness.AuditReview`)
- Quick probes or A/B experiments where you don't need the full worktree + verification lifecycle
- Situations where you just want raw transcript + `Outcome`

```elixir
invocation = %Harness.AgentAdapter.Invocation{
  prompt: "...",
  cwd: "/abs/path/to/probe/worktree",   # see cwd guidance below
  task_id: "probe-42",
  # permission_mode, session, env, model, adapter_opts, rules, etc.
}

{:ok, %Harness.AgentAdapter.Outcome{} = outcome} =
  Harness.AgentAdapter.Driver.run(Harness.AgentAdapter.Grok, invocation,
    total_timeout: 1_800_000,
    idle_timeout: 300_000
  )
```

**`cwd` guidance.** The Driver does not manage `cwd` — it's whatever you put on the `Invocation`. The right value depends on the call shape:
- **Grading via `AuditReview.grade_fix/1`** — leave it; the wrapper defaults `cwd` to `File.cwd!/0`, which is the right answer for read-only diff review.
- **Ad-hoc probes / A/B experiments** — pass a real worktree path you control (typically one you constructed with `Harness.Worktree.create/2` and will clean up yourself). A throwaway `/tmp` path is fine for read-only probes; for anything that may write, it must be a git worktree the adapter can commit into.

`AuditReview.grade_fix/1` is the packaged version of this for HIGH-tier reviews. Worth knowing its optional knobs:
- `:grader` — defaults to the opposite of `:implementer` for `:claude`/`:codex`; other implementers require explicit `:grader`.
- `:cwd` — defaults to `File.cwd!/0`.
- `:model` — pin a specific model id (e.g. `"claude-opus-4-7"` when grading higher-stakes fixes).
- `:total_timeout` / `:idle_timeout` — forwarded to `Driver`.

---

## Reading and Acting on Results

Always read `Harness.Run.Result` (or the `Outcome` from the cheap path). The verdict table in `docs/dogfooding-workflow.md` is still the best reference for what the various states + reasons mean and what action you should take.

Key fields you care about as orchestrator (full struct: `lib/harness/run/result.ex`):
- `state` + `reason`
- `verdict` (the structured check results)
- `agent_outcome` (raw transcript + kind + exit_status)
- `worktree_path` (the deliverable; the branch name is conventionally `"harness/" <> run_id` — not stored on `Result`)
- `repair_attempts`
- `first_attempt_failed_check_count`, `agent_diff_size` (diagnostics)

Never trust `agent_outcome.exit_status` or the agent's self-reported success.

---

## Recommended Patterns (copy these)

**Single delegation with explicit adapter choice:**

```elixir
{:ok, project} = Harness.ProjectRegistry.lookup("my_project")
{:ok, item}    = Harness.Roadmap.ingest(:next, project: project)
adapter        = pick_adapter_for_task(item)   # your logic (cost, capability, A/B, etc.)

{:ok, run_id, _pid} = Harness.Run.Supervisor.start_run(
  item, project, adapter,
  subscriber: self(),
  env: scrub_keys_for_agent(adapter)
)
```

**Fire-and-forget batch (Oban-persisted, per-project queue):**

```elixir
{:ok, jobs} = Harness.Batch.dispatch(project, items)
# concurrency = project.concurrency_cap (set when the project was registered)
```

**In-process batch with explicit cap + retry policy:**

```elixir
{:ok, results} = Harness.Batch.run(items, project, Harness.AgentAdapter.Claude,
  max_concurrency: 3,
  retry_policy: [],
  required_capabilities: []
)
```

**Cross-agent audit grade (HIGH-tier):**

```elixir
{:ok, %{verdict: v, outcome: o, grader: g}} =
  Harness.AuditReview.grade_fix(
    implementer: :claude,
    sha: "abc1234",
    prompt: "Review the diff at the commit. Emit <<<VERDICT:APPROVE>>> or <<<VERDICT:REJECT>>> on its own line at the end."
  )
```

---

## Sharp Edges & Gotchas (2026-05 post-v0_5)

- **No first-class MCP surface yet** (Task 17 deferred). You drive via `project_eval` (Tidewave) or IEx today. The library + dashboard is the current agent surface.
- **AgentRegistry is a soft hint, not a contract** (Task 40 resolved 2026-05-27 as option (b)). Unavailability state is in-memory only and clears on GenServer restart **by design** — the registry is a latency optimization to skip known-bad adapters at dispatch; correctness lives in Oban (workers map quota → `{:snooze, _}`, persisted job rows survive both restarts and quota windows). Bounded cost of a restart-clear: one wasted first-attempt per previously-marked-unavailable adapter. Don't trust quota state across BEAM restarts; do trust Oban retry. Also: Task 41 (Codex worktree-isolation regression) is **resolved as of 2026-05-27** — `codex exec --cd <cwd>` pins the working root at the exec level, mirroring the Task 32 fix shape. Full rationale: `Harness.AgentRegistry` `@moduledoc` § "Availability is a soft hint, not a contract".
- **Worktree isolation is enforced via capability + guard.** Only `Harness.AgentAdapter.Antigravity` currently declares `worktree_isolation: false`; the dispatch guard (`Harness.Worktree.Isolation`) refuses to start a worktree-isolated run on a non-isolating adapter and snapshots the main checkout porcelain mid-run to trap pollution (Task 32). Past regressions all live on `:checkout_polluted` reason — see `docs/dogfooding-workflow.md` verdict table. Task 60 (2026-05-27) added a four-tier pollution allowlist (run opts → project → app config → `default_pollution_allowlist/0`) that ignores incidental `.claude/`, `.DS_Store`, and editor temp/lock writes; roadmap files are deliberately NOT allowlisted (a genuine agent mutation to them is a bug worth catching). Note: running `rmap` mutations in a parallel session against the same checkout will also trigger `:checkout_polluted` — a false positive caused by the operator, not the agent (see `docs/dogfooding-workflow.md` § "Known sharp edges").
- **Non-delegatable two-step dance**: Easy to forget. The skill exists partly to make this impossible to miss. Distinct from worktree isolation (see § "Non-delegatable adapters" above for both axes).
- **Results are delivered to the subscriber** but not automatically persisted beyond Oban job rows (Task 19). Keep the transcript if you need it later.
- **Cold verification** (especially dialyzer PLT) can be slow on first run in a fresh worktree.
- **Secret scrubbing**: Use the `:env` map with `false` values. Do this explicitly for any key that might shadow a subscription (classic `ANTHROPIC_API_KEY` shadowing Claude's OAuth case).

---

## When to Bypass Harness (rare)

Only for:
- Foundational scaffolding that changes the supervision tree, dep stack, or Endpoint while the verification stack itself is in flux (the v0_5 precedent).
- True emergencies where the harness path is broken and you have filed the gap.

A new phase that only adds features on stable surfaces does **not** earn a hand-build window.

---

## Anti-Staleness Contract (for future maintainers and rmap tasks)

**This file must be updated when the driver surface changes.**

Changes that require an update to this skill:
- New or changed fields on `Harness.AgentAdapter.Invocation`
- New `rule_channel` values or rule injection behavior
- New public functions on `Harness.Run.Supervisor`, `Harness.Batch`, `Harness.Roadmap`, `Harness.AgentAdapter.Driver`
- New adapters or capability declarations
- Changes to the non-delegatable contract or recommended dispatch paths
- New result shapes or verdict semantics
- Task 17 (MCP surface) when it lands

**How this skill reaches the orchestrator's context.** The project `CLAUDE.md` imports this file via `@skills/harness-driver/SKILL.md`, so it loads at session start in this repo. In consumer projects that depend on harness, the skill is meant to be loaded the same way — `@`-import from their CLAUDE.md (or invoke explicitly via the Skill tool when triggered by the patterns in the `argument-hint`). It does not auto-load on its own.

When in doubt, read the current moduledocs for `Harness.AgentAdapter`, `Harness.Run`, `Harness.Batch`, and `Harness.Roadmap`, then make this skill match reality. Tidewave `project_eval` is the fastest verifier: `function_exported?/3`, `__info__(:functions)`, `Map.keys(Struct.__struct__())`, and `get_docs` will catch most drift in seconds.

---

## Related Canonical Documents

- `CLAUDE.md` § "Dogfooding — harness Builds harness" (policy)
- `docs/dogfooding-workflow.md` (detailed operational runbook + verdict table + driver script template)
- `docs/agent-cli-reference.md` (per-agent headless facts)
- `ROADMAP.md` (current phase and open tasks)

Load those in addition to this skill when doing deep harness orchestration work.

---

**This skill is the thing an AI should load first when it finds itself in a context where harness is available as a delegation engine.**

Use it. Keep it accurate. Dispatch through harness.