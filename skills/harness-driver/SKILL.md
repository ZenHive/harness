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
# Single task (most common)
{:ok, item} = Harness.Roadmap.ingest({:id, "123"}, project: "my_project")
{:ok, run_id, pid} = Harness.Run.Supervisor.start_run(
  item,
  project,
  Harness.AgentAdapter.Grok,     # or .Claude, .Codex, .Cursor, etc.
  subscriber: self(),
  lifetime_timeout: 3_600_000,
  env: %{"SOME_KEY" => false}    # scrub inherited secrets
)

# Wait for result
receive do
  {:harness_run, ^run_id, %Harness.Run.Result{} = result} -> result
end
```

For Oban-backed dispatch (preferred for persistence + restart resilience):

```elixir
{:ok, jobs} = Harness.Batch.dispatch(project, [item1, item2])
# or per-project: Harness.dispatch(project, items)
```

**Non-delegatable adapters (Grok, Antigravity, Pi):**

These cannot be passed to `Harness.Roadmap.ingest(agent: :grok)`.

Two-step pattern (do not skip):

1. Ingest using a delegatable agent (`:claude`, `:codex`, or `:cursor`).
2. Pass the resulting `%Harness.Roadmap.Item{}` directly to `Harness.Run.Supervisor.start_run(item, project, Harness.AgentAdapter.Grok, ...)`.

The skill explicitly calls this out so you don't make the common mistake.

### 2. Cheap / Direct Driver Path (`Harness.AgentAdapter.Driver.run/3`)

Use for:
- Cross-agent grading (`Harness.AuditReview`)
- Quick probes or A/B experiments where you don't need the full worktree + verification lifecycle
- Situations where you just want raw transcript + `Outcome`

```elixir
invocation = %Harness.AgentAdapter.Invocation{
  prompt: "...",
  cwd: "/tmp/some-worktree-or-temp-dir",
  task_id: "probe-42",
  # permission_mode, session, env, model, etc.
}

{:ok, %Harness.AgentAdapter.Outcome{} = outcome} =
  Harness.AgentAdapter.Driver.run(Harness.AgentAdapter.Grok, invocation,
    total_timeout: 1_800_000,
    idle_timeout: 300_000
  )
```

`AuditReview.grade_fix/1` is the packaged version of this for HIGH-tier reviews.

---

## Reading and Acting on Results

Always read `Harness.Run.Result` (or the `Outcome` from the cheap path). The verdict table in `docs/dogfooding-workflow.md` is still the best reference for what the various states + reasons mean and what action you should take.

Key fields you care about as orchestrator:
- `state` + `reason`
- `verdict` (the structured check results)
- `agent_outcome` (raw transcript + kind + exit_status)
- `worktree_path` and `branch` (for the deliverable)
- `repair_attempts`

Never trust `agent_outcome.exit_status` or the agent's self-reported success.

---

## Recommended Patterns (copy these)

**Single delegation with explicit adapter choice:**

```elixir
{:ok, item} = Harness.Roadmap.ingest(:next, project: project)
adapter = pick_adapter_for_task(item)   # your logic (cost, capability, A/B, etc.)

{:ok, run_id, _pid} = Harness.Run.Supervisor.start_run(
  item, project, adapter,
  subscriber: self(),
  env: scrub_keys_for_agent(adapter)
)
```

**Batch with concurrency cap (Oban path):**

```elixir
{:ok, jobs} = Harness.Batch.dispatch("my_project", items, max_concurrency: 3)
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
- **AgentRegistry restart behavior** (Task 40 open): In-memory unavailable state is lost on GenServer restart. Quota failover can temporarily look broken after a BEAM restart.
- **Worktree isolation is still enforced but has had regressions**: Some agents have ignored `cwd` in the past. The `Harness.Worktree.Isolation` guard + capability declaration exists for this reason.
- **Non-delegatable two-step dance**: Easy to forget. The skill exists partly to make this impossible to miss.
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

**Marker for automation / human review:**

<!-- DRIVER-SURFACE:BEGIN -->
The content between these markers is the canonical "how an AI drives harness" contract.
Any task touching the surfaces above must update this section and the surrounding guidance.
<!-- DRIVER-SURFACE:END -->

When in doubt, read the current moduledocs for `Harness.AgentAdapter`, `Harness.Run`, `Harness.Batch`, and `Harness.Roadmap`, then make this skill match reality.

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