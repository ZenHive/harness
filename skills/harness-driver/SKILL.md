---
name: harness-driver
description: >
  How an AI orchestrator (Claude Code, Cursor, Grok, etc.) uses harness as its primary
  delegation engine. Covers BOTH driving harness from inside the harness checkout
  (dogfooding) AND from a different consuming repo (the more common case). The stable
  contract, setup, recommended patterns, and sharp edges for getting verified agent
  work through harness instead of hand-building or raw calls.
when-to-use: "Use when you are the orchestrator and want to delegate work via harness (rmap tasks, verified runs, cross-agent grading, A/B evaluation, etc.) — whether you are inside the harness checkout itself or driving it from a different repo. Read this before writing custom driver scripts."
argument-hint: "harness driver | delegate via harness | use harness for this task | drive harness from my repo"
---

# Harness Driver Skill

**Purpose:** Make harness the default, reliable way an AI gets work done with verification, isolation, and restart resilience — instead of raw agent calls or hand-building.

**Three roles to keep straight:**

| Role | Who | Where it lives |
|---|---|---|
| **Operator** | Human | Starts `iex -S mix` in `~/_DATA/code/harness/`, registers projects, watches the dashboard |
| **Driver** | You — the AI orchestrator reading this | Dispatches via harness's **native flat MCP tools** (`mcp__harness__dispatch-*`, etc.) against harness's `:4018` BEAM; drops to `project_eval` only for arbitrary eval / struct-surface ops; reads verdict summaries / `%LogRecord{}` |
| **Implementer** | The headless agent harness spawns (Claude / Codex / Cursor / Grok / Antigravity / Pi) | Runs in an isolated git worktree harness manages, gated by a cross-family **reviewer AI** — **not you** |

You (driver) do not run the implementation work. You decide which task, which adapter, which env scrubbing — then dispatch and read the reviewer's verdict.

**Post-v0_5 reality:** Harness is a multi-project OTP node with Oban dispatch, per-project queues, restart resilience, Phoenix LiveView dashboard + Oban Web, a **native MCP server** (`/harness/mcp`, flat JSON tools) AND a Tidewave MCP plug (`/tidewave/mcp`, `project_eval` escape hatch) all on one Bandit endpoint (`http://localhost:4018`), and `Oban.Plugins.Cron` for autonomous polling. **The native MCP tools are the primary driver surface; `project_eval` is the escape hatch** — see § "Primary Surface" below.

---

## Two Contexts (read the one that applies to you)

### Context A — Driving harness from another repo (the common case)

You are an AI agent in `~/_DATA/code/myapp/` (or wherever). You want harness — which is running as a long-lived `iex -S mix` BEAM in `~/_DATA/code/harness/` — to take a task from `myapp`'s roadmap, dispatch it to a headless agent in an isolated worktree of `myapp`, have a cross-family reviewer AI gate the result (it runs `myapp`'s own checks itself and fixes inline), and give you the reviewer's verdict.

Four setup steps the consuming repo needs:

**1. Operator runs harness.** A `iex -S mix` session in `~/_DATA/code/harness/`. This boots the dashboard at `http://localhost:4018`, the **native MCP server** at `http://localhost:4018/harness/mcp` (the flat driver tools), the Tidewave MCP plug at `http://localhost:4018/tidewave/mcp` (the `project_eval` escape hatch), Oban queues, the lot. Verify by opening `http://localhost:4018/harness` in a browser.

**2. Register `myapp` with harness.** Three paths:

- **Host-local (preferred for personal projects):** create `~/_DATA/code/harness/config/dev.local.exs` (gitignored — template at `config/dev.local.exs.example`), then restart `iex -S mix`. The local file REPLACES the default `:projects` list, so include the `"harness"` self-entry alongside your own:

  ```elixir
  # ~/_DATA/code/harness/config/dev.local.exs
  import Config

  config :harness, :projects, [
    [
      name: "harness",
      source: {:local, Path.expand("..", __DIR__)},
      check_command: "mix precommit.full",
      roadmap_path: Path.expand("..", __DIR__)
    ],
    [
      name: "myapp",
      source: {:local, "/Users/efries/_DATA/code/myapp"},
      # `check_command` is a free-text hint handed to the reviewer AI — the
      # reviewer runs the project's checks itself and judges the output;
      # harness never executes this command. For a multi-language monorepo,
      # just describe both: "cd rust && cargo test; cd elixir && mix precommit".
      check_command: "mix precommit",
      roadmap_path: "/Users/efries/_DATA/code/myapp",
      concurrency_cap: 2
    ]
  ]
  ```

- **Shared / committed:** if the project belongs in the harness repo's tracked config (every contributor should see it), add the same entry to `config/dev.exs` instead and commit. Use this only when the registration is genuinely shared — host-specific paths belong in `dev.local.exs`.

- **Ad-hoc (one-shot):** dispatch `Harness.ProjectRegistry.register/1` via the `project_eval` escape hatch (`mcp__harness_eval__project_eval`, wired in step 3). Cleared on next BEAM restart — fine for experiments, not for ongoing work.

**3. Add harness's MCP endpoints to `myapp`'s `.mcp.json`.** This is the load-bearing step that wires the driver (you) to harness. Add the native server (your primary surface) and, optionally, the eval escape hatch — alongside `myapp`'s own Tidewave (if it has one):

```json
{
  "mcpServers": {
    "tidewave": {
      "type": "http",
      "url": "http://localhost:4001/tidewave/mcp"
    },
    "harness": {
      "type": "http",
      "url": "http://localhost:4018/harness/mcp"
    },
    "harness_eval": {
      "type": "http",
      "url": "http://localhost:4018/tidewave/mcp"
    }
  }
}
```

**Naming matters.** Claude Code surfaces a server's tools as `mcp__<server-name>__<tool>`, so these three names give you three distinguishable surfaces:

- `mcp__tidewave__*` (e.g. `project_eval`) — inspect `myapp`'s own BEAM state (port 4001).
- `mcp__harness__*` — harness's **native flat driver tools** (`dispatch-task`, `dispatch-status`, `dispatch-verdict_detail`, `roadmap-*`, …) against harness's `:4018` BEAM. **This is your primary surface** — see § "Primary Surface" below.
- `mcp__harness_eval__project_eval` — the **escape hatch**: arbitrary Elixir inside harness's `:4018` BEAM, for the struct-surface ops the flat tools deliberately omit (`Run.Supervisor.start_run/4`, `Batch.run/4`, ad-hoc `ProjectRegistry.register/1`). Optional — skip it if you only need the flat tools.

No port collision: different BEAMs / paths. No curl needed — MCP-over-HTTP handles transport. If you don't need arbitrary eval into harness, drop the `harness_eval` entry entirely.

**4. Import this skill from `myapp`'s `CLAUDE.md`.**

```
@~/_DATA/code/harness/skills/harness-driver/SKILL.md
```

`myapp`'s CLAUDE.md is otherwise the place to describe `myapp`'s domain, conventions, and check commands — none of that gets dragged into harness. The skill carries the harness-side contract.

**Then restart your Claude Code session** so the new `.mcp.json` entries are picked up. Verify by checking the tool list contains `mcp__harness__dispatch-task` (and the rest of the flat surface).

After these four steps, the default dispatch path from `myapp` is the native `mcp__harness__dispatch-*` tools, with `mcp__harness_eval__project_eval` as the escape hatch.

### Context B — Dogfooding inside the harness checkout

You are an AI agent in `~/_DATA/code/harness/` itself, building harness with harness. The skill is already imported via `@skills/harness-driver/SKILL.md` from harness's CLAUDE.md. Harness's own `.mcp.json` wires **two** entries against its single `:4018` BEAM: a `harness` entry at `/harness/mcp` (the native flat tools → `mcp__harness__dispatch-*`) and a `tidewave` entry at `/tidewave/mcp` (the escape hatch → `mcp__tidewave__project_eval`).

So in this context the names collapse: the native dispatch tools are `mcp__harness__dispatch-*` (same as Context A), and the `project_eval` escape hatch is `mcp__tidewave__project_eval` (Context A's `mcp__harness_eval__project_eval`). Everything else applies identically.

---

## Core Principle

**Never hand-build what harness can dispatch.**

- **Consuming-repo context (A):** dispatching is the default. You're not the implementer at all — you dispatch and read verified results. Hand-building from inside your own session defeats the whole role split.
- **Dogfooding context (B):** dispatching is the default for anything that isn't trivial. Hand-build only when harness genuinely cannot yet do it (rare, and only after filing via `rmap new`).

The cross-family reviewer AI's verdict — not the implementer's self-report — is always the source of truth.

**Always reach for the native flat MCP tools first** (next section). The Elixir struct surface (`start_run`, `Batch`, `compare`) over `project_eval` is the escape hatch for the handful of ops the flat tools deliberately omit — not the default.

**Token-economy carve-out (dogfooding only).** Inside the harness checkout, a task with all of D≤2 + ≤30 LOC across ≤3 files + no harness-surface change (no new adapter / behaviour callback / supervision-tree / run-lifecycle edit) may be hand-built. Two ~15-LOC fixes burn more orchestration tokens through `Batch.dispatch/2` than they save in integration signal — the dispatch lifecycle isn't meaningfully exercised at that size. This carve-out does NOT apply in the consuming-repo context: there you have no in-checkout option, and the orchestration token cost is offset by the role split (you'd otherwise context-switch into the consuming repo's BEAM yourself). Full rationale and the matching policy bullet live in `CLAUDE.md` § Dogfooding.

---

## Primary Surface: Native Flat MCP Tools (`mcp__harness__*`)

**This is the default way you drive harness.** Harness ships its own MCP server (`Harness.Dashboard.MCPServer`, on `anubis_mcp`) at `http://localhost:4018/harness/mcp`, exposing the descripex-annotated driver surface as flat, JSON-native tools. Wired per the setup above, Claude Code surfaces each as `mcp__harness__<tool>` — **no Elixir, no struct passing, no `project_eval` for the common path.** The whole dispatch → observe → triage loop is JSON-native end to end:

| Tool | Does |
|---|---|
| `dispatch-task` | Dispatch one roadmap task fire-and-forget → returns a `run_id`. |
| `dispatch-await` | Dispatch + block until settled → compact verdict summary (bounded by `timeout_ms`; on timeout returns a `:timed_out` summary, run keeps going). |
| `dispatch-recommend` | Recommend an agent for a capability domain from persisted scores: explore unmeasured cells, exploit best fresh/discounted score. |
| `dispatch-bundle` | Fan out the next session-sized bundle → one Oban-backed job per task (any of the six adapters: claude/codex/cursor/grok/antigravity/pi). |
| `dispatch-compare` | Same-task A/B across N adapters in isolated worktrees → side-by-side per-adapter metrics. All six executors. |
| `dispatch-status` | Live snapshot of an in-flight (or 5s-lingering) run by `run_id`: state, review verdict so far, agent pid. |
| `dispatch-transcript` / `dispatch-transcript_events` | Buffered raw / parsed transcript for a live run, with a `seq` to poll deltas. |
| `dispatch-cancel` | Cancel an in-flight run (idempotent). |
| `dispatch-hold` / `dispatch-steer` / `dispatch-resume` | Operator-mediated run recovery by `run_id`: park a run (`hold`, `interrupt:` to kill the agent now), stash guidance for the next agent boundary (`steer`), re-enter `:running` in the same worktree (`resume`). The JSON-native counterparts to `Harness.Run.hold/2` · `steer/2` · `resume/1`. |
| `dispatch-resume_failed` | Recover a SETTLED `:failed` run by `run_id`: re-dispatch its roadmap task on a NEW run branched off the retained `harness/<run-id>` branch (prior commits are the start point) with the failure report injected. Same agent by default; `escalate: true` routes via capability score to the recommended agent. DISTINCT from `dispatch-resume` (which un-pauses a live `:held` run). |
| `dispatch-reland` | Re-enqueue the landing job for a run whose land-train hit its cap and left the task `blocked`. Pure git, reviewer-approved branch — **zero agent tokens**. `Harness.Dispatch.reland/1` → `Harness.Lander.enqueue/1`. |
| `dispatch-verdict_detail` | After settle, read the **reviewer's verdict / report / ratings** by `run_id` — loaded from the persisted record, so it works after the run process is gone. |
| `dispatch-register_project` | Register a project for dispatch from JSON scalars (`name`, `source_type` local/github, `source_location`, `roadmap_path`, optional `check_command` / `concurrency_cap`) — the JSON-native path for `Harness.ProjectRegistry.register/1` (which takes a struct). Runtime-only unless `:repo_enabled`; durable registration stays config + restart. |
| `roadmap-list` / `roadmap-next_bundle` / `roadmap-ingest` | Browse / ingest a registered project's roadmap as structured data. |
| `roadmap-ready` | The parallel-safe, headless-dispatchable task set (`rmap ready --dispatchable`) — every pending task with all deps done, `handbuild` excluded; returns `id`, `assignee`, and `markers` for autonomous routing; mutually independent, safe to fan out as one batch. |
| `roadmap-mark_landed` / `roadmap-mark_blocked` | Write a run's outcome back to the roadmap: `done --verified --shipped-in <sha>` after a successful land; `blocked --reason "..."` as the terminal sink. |
| `project_registry-list` / `project_registry-lookup` | Discover registered project names + config. |
| `result_store-list_run_records` | Settled-run records (reviewer verdict / report / ratings, reviewer fix-diff size, transcript, token usage). |
| `playbooks-list` / `playbooks-get` | Ready-made orchestration recipes. |
| `audit_review-grade_fix` | Cross-agent HIGH-tier grade of a commit. |

**Canonical loop, zero Elixir:** `dispatch-task` (or `dispatch-bundle`) → `dispatch-status` / `dispatch-transcript` to watch → `dispatch-verdict_detail` to read the reviewer's report on a rejected run. Or collapse the wait into one `dispatch-await` call when you want the verdict in-band.

`project_eval` is deliberately **not** on this surface — it's the escape hatch (next section), reached for only when you need arbitrary eval or one of the struct-passing ops the flat tools omit (`supervisor-start_run`, `batch-*`, `agent_evaluation-compare`, `audit_review-grade_fix_with`). The Manifest's `:exchange_data` filter is what keeps those off the JSON surface; the flat wrappers above are the JSON-native way around it. For the full descripex/MCP mechanics, see § "Driving via Chat / MCP".

---

## Escape Hatch: The Elixir Struct Surface (`project_eval` / IEx)

> Reach for this surface only when the flat tools above don't cover what you need — arbitrary eval, or the struct-passing ops they omit. In **Context A** the eval tool is `mcp__harness_eval__project_eval`; in **Context B** (dogfooding) it's `mcp__tidewave__project_eval`. The patterns below are written with the bare Elixir calls — run them through whichever eval tool your context wires.

### 1. Full Verified Lifecycle (the struct-level dispatch path)

Use when you want the complete harness guarantees *and* need struct-level control the flat `dispatch-*` tools don't expose:

- Isolated git worktree (`harness/<run-id>` branch)
- Harness-owned rule injection
- Commit of the agent's work before teardown
- A cross-family **reviewer AI as the gate** — it reviews against the acceptance criteria, runs the project's checks itself, fixes inline, and writes `.harness/review.json`
- Proper `Harness.Run.Result` with the parsed review artifact (`verdict` / `report` / `ratings`)

**Entry points (Elixir, callable via the `project_eval` escape hatch — `mcp__harness_eval__project_eval` / `mcp__tidewave__project_eval` — or IEx):**

```elixir
# Fetch the registered project (a %Harness.Project{}, NOT a string).
{:ok, project} = Harness.ProjectRegistry.lookup("myapp")

# Single task (most common)
{:ok, item} = Harness.Roadmap.ingest({:id, "123"}, project: project)
{:ok, run_id, pid} = Harness.Run.Supervisor.start_run(
  item,
  project,                          # must be %Harness.Project{} — guarded
  Harness.AgentAdapter.Claude,      # or .Codex, .Cursor, .Grok, .Antigravity, .Pi
  subscriber: self(),
  lifetime_timeout: 3_600_000,
  env: %{"ANTHROPIC_API_KEY" => false}  # scrub inherited secrets (Claude OAuth case)
)

# Wait for result (only valid if `self()` outlives the run — see the
# two-eval pattern below for the Tidewave-from-driver case)
receive do
  {:harness_run, ^run_id, %Harness.Run.Result{} = result} -> result
end
```

`Roadmap.ingest/2` options worth knowing:
- `:project` — `%Harness.Project{}`; supplies `roadmap_path`. Use this for registered projects.
- `:project_root` — string path; fallback when `:project` is omitted. Defaults to `File.cwd!/0` (which is harness's cwd when called via `project_eval` — almost never what you want; pass `:project` explicitly).
- `:agent` — any of the six harness adapters `rmap delegate --to` renders natively: `:claude | :codex | :cursor | :grok | :antigravity | :pi`. Defaults to `:claude`. The ingested prompt is rendered for *this* agent and runs directly on its adapter. `:droid` (or any agent without a harness adapter) is rejected — see "Renderable vs executable agents" below.
- `:rmap_bin` — override the `rmap` binary name/path.

**Browsing a roadmap before you ingest.** To see *what's there* — pick a task id, scope a session — use the structured browse functions instead of shelling `rmap` into the live checkout (which is wrong from harness's cwd, and breaks for `{:github, _}` sources):

```elixir
# All tasks (or filter by rmap status), resolved by registered project name.
{:ok, tasks} = Harness.Roadmap.list("myapp")              # every task
{:ok, pending} = Harness.Roadmap.list("myapp", "pending") # status filter

# Next session-sized bundle of pending tasks + its bundle metadata.
{:ok, %{bundle: bundle, tasks: tasks}} = Harness.Roadmap.next_bundle("myapp")
```

- Both take a **registered project name string** (resolved via `ProjectRegistry.lookup/1` → `roadmap_path`) — the flat, JSON-native shape the MCP/chat orchestrator calls as the `roadmap-list` / `roadmap-next_bundle` tools. SOURCE valid names from `project_registry-list`.
- `list/2` returns `{:ok, [task_map]}` — each map carries `id`, `title`, `status`, `phase`, `bundle`, `eff`, `markers`, `milestone`. Finer filters (phase/marker/bundle/milestone) are client-side on the returned list; only `status` is pushed to rmap.
- `next_bundle/1` returns `{:ok, %{bundle: meta | nil, tasks: [...]}}` (`bundle: nil` when nothing is pending).
- `ready/1` is the **parallel-safe dispatch set** (`rmap ready --dispatchable --fields id,assignee,markers`): every pending task whose deps are all done, `handbuild` excluded — mutually independent, safe to fan out as one batch (the cron poller's selection surface; MCP tool `roadmap-ready`). `assignee` is the autonomous-routing field; `model` is a free-text LLM pin and is not requested here. Takes the same working-root opts as `ingest/2` (`:project` > `:project_name` > `:project_root` > cwd).
- Both error `{:error, {:unknown_project, name}}` for an unregistered name, plus the same `rmap_*` reasons as `ingest/2`.

`Run.Supervisor.start_run/4` options worth knowing (full list in moduledoc):
- `:subscriber` — pid that receives `{:harness_run, run_id, result}`. Defaults to caller. **Pass `nil` when dispatching from a `project_eval` escape-hatch snippet** (eval process is ephemeral; see two-eval pattern).
- `:total_timeout` / `:idle_timeout` — agent run timeouts (forwarded to `Driver`).
- `:lifetime_timeout` — whole-job wall budget in ms.
- `:adapter_opts` — per-adapter knobs forwarded to `Invocation`.
- `:required_capabilities` — gated at dispatch; the run won't start if the selected adapter lacks them.
- `:retry_policy` — `%Harness.Run.RetryPolicy{}` or keyword list; pure backoff arithmetic for crash-only mechanical retry.
- `:reviewer` / `:reviewer_adapter_opts` — explicit reviewer adapter override (defaults to cross-family auto-selection).
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

**Renderable vs executable agents:**

`rmap delegate --to` renders a native prompt for all six harness adapters — `:claude`, `:codex`, `:cursor`, `:grok`, `:antigravity`, `:pi` — so every one is a first-class `ingest(agent: …)` target dispatched directly on its own adapter. There is no claude-rendered two-step anymore: just `ingest(agent: :grok)` → `start_run(item, project, Harness.AgentAdapter.Grok, ...)`.

rmap can also render an agent harness has **no adapter for** (currently `droid`). `ingest(agent: :droid)` is rejected (`{:invalid_agent, :droid}`) because there is no executor to run the prompt, and `dispatch-task adapter: "droid"` rejects as `{:unknown_adapter, "droid"}`. Adding an executor is two-sided: an rmap-lib `--to` target (the rmap binary is ours at `../rmap/` — already shipped for `droid`) **plus** a harness `AgentAdapter` added to `Harness.Roadmap`'s `@valid_agents` and `Harness.AgentAdapter.Registry`.

> **Worktree isolation is a separate, orthogonal axis.** All six shipped adapters currently declare `worktree_isolation: true`. `agy` ignores Port `cwd` for writes unless the adapter also passes `--add-dir <worktree>` (Task 32/198 — mirrors Codex `exec --cd`, Task 41). The dispatch guard (`Harness.Worktree.Isolation`) still refuses to start a worktree-isolated run on any future adapter that declares `false`. This is independent of whether rmap can render the agent.

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
- **Grading via `AuditReview.grade_fix/1`** — leave it; the wrapper defaults `cwd` to `File.cwd!/0`. **In Context A (driver in another repo), `File.cwd!/0` is harness's own cwd**, which is rarely what you want for grading another repo's diff. Pass `cwd:` explicitly to the consuming repo's path.
- **Ad-hoc probes / A/B experiments** — pass a real worktree path you control (typically one you constructed with `Harness.Worktree.create/2` and will clean up yourself). A throwaway `/tmp` path is fine for read-only probes; for anything that may write, it must be a git worktree the adapter can commit into.

`AuditReview.grade_fix/1` is the packaged version of this for HIGH-tier reviews. Worth knowing its optional knobs:
- `:grader` — defaults to the cross-family pair from `config :harness, :audit_review, grader_pairs:` (built-in default: `:codex` for `:claude` and vice versa); implementers absent from the pair map require explicit `:grader`.
- `:cwd` — defaults to `File.cwd!/0` (see caveat above for Context A).
- `:model` — pin a specific model id (e.g. `"claude-opus-4-7"` when grading higher-stakes fixes).
- `:total_timeout` / `:idle_timeout` — forwarded to `Driver`.

---

## Reading and Acting on Results

Always read `Harness.Run.Result` (or the `Outcome` from the cheap path). The verdict table in `@~/.claude/includes/harness-workflow.md` (promoted from docs/dogfooding-workflow.md) is the reference for states + reasons + actions; `docs/dogfooding-workflow.md` retains the harness-incubator driver template and cutover log.

Key fields you care about as driver (full struct: `lib/harness/run/result.ex`):
- `state` + `reason` — `:done`/`:approved`, or `:failed` with `{:review_rejected, report}` / `{:review_stuck, report}` / a mechanical reason
- `review` — the parsed `.harness/review.json` artifact (`%Harness.Run.Review{verdict, report, ratings}`)
- `agent_outcome` (raw implementer transcript + kind + exit_status)
- `worktree_path` (the deliverable; the branch name is conventionally `"harness/" <> run_id` — not stored on `Result`)
- `agent_diff_size`, `reviewer_diff_size` (diagnostics; reviewer diff `0` = first-attempt pass)
- `reviewer_adapter` (which cross-family agent gated the run)

Never trust `agent_outcome.exit_status` or the implementer's self-reported success.

**Worktree provisioning.** A fresh git worktree has no `deps/` or `_build/` (both gitignored). There is no mechanical bootstrap — the implementer and the reviewer each run `mix deps.get` themselves when they need to compile or test. Budget the run's timeouts for a cold dep build, and write `check_command` hints that assume a cold worktree.

---

## Driving via Chat / MCP (Phase 9, milestone v0_7)

A third consumer surface — alongside `Harness.Run.Supervisor.start_run/4` (verified lifecycle) and `Harness.AgentAdapter.Driver.run/3` (cheap path) — lets an operator drive harness through a natural-language chat session backed by a tool-equipped LLM. Two pieces:

### Chat backend (in-process)

`Harness.Chat.Session` is a per-session GenServer that runs a multi-turn tool-call loop against any module implementing the `Harness.Chat.Backend` behaviour. The default and only shipped backend is `Harness.Chat.Claude` — a raw-Port wrapper around `claude -p --output-format stream-json` that runs on the **Claude subscription path** (`ANTHROPIC_API_KEY` is scrubbed to `false` in the Port env, so the spawned binary uses its OAuth refresh token, not a metered API key).

Boot a session and send a turn:

```elixir
{:ok, session_id, _pid} = Harness.Chat.Supervisor.start_session(
  backend: Harness.Chat.Claude,
  backend_opts: [
    # Optional. Defaults to a per-session cwd under System.tmp_dir!()
    # so claude -p's --continue resume is anchored cleanly per session.
    cwd: "/tmp/harness-chat/my-session"
  ]
)

{:ok, response} = Harness.Chat.Session.user_message(session_id, "list pending v0_7 tasks")
```

Stream the session live by subscribing to `Phoenix.PubSub` topic `"harness:chat:" <> session_id` — the LiveView at `http://localhost:4018/harness/chat/<session_id>` does exactly this. Events fan out as maps: `%{type: "text_delta", text: ...}`, `%{type: "tool_call", id:, name:, arguments:}`, `%{type: "tool_result", id:, name:, content:}`, `%{type: "done", response: ...}`, `%{type: :terminal, reason:, message:}`.

`Harness.Chat.Session.cancel/1` interrupts an in-flight turn (the dashboard's Stop button calls it). Because a turn runs synchronously inside the session GenServer, cancel is a bare `send(pid, :harness_cancel)` — not a cast — which a backend parked in a `receive` (e.g. `Harness.Chat.Claude`'s Port drive loop) matches to tear down its work and return `{:error, %{type: :cancelled}}`, surfacing as a `:terminal` with `reason: :cancelled`. Always returns `:ok` (no-op on an unknown or idle session); prior conversation history is preserved. A backend opts into mid-turn cancellation by handling `:harness_cancel` in its stream `receive`.

`:backend` is **required** on `Session.init/1` — no implicit default. The session injects its own `session_id` into `backend_opts` before each `stream/3` call so backends can derive a stable per-session workspace without an extra registration step.

**Persistence + index (Task 93).** Chat transcripts survive a BEAM restart via `Harness.Chat.Store` — a file-backed term store (mirrors the ResultStore file backend pattern) under the `config :harness, :chat_store, root: …` path (`false` disables it). `Session` persists its `:messages` after each completed turn and rehydrates them on `init/1`, so reopening `/harness/chat/<session_id>` after a restart replays the prior turns (history is bounded to the most recent 200 messages, mirroring the live cap). The bare `/harness/chat` route is now the **`:index`** action: it lists live sessions (`Harness.Chat.Supervisor.list_sessions/0`, over `Harness.Chat.Registry`) merged with persisted-but-dead ones from the store — each with a derived label, message count, last-activity, and a deep link; the "New chat" button mints a fresh session. `Store.save/3` / `load/2` / `list/1` are the store surface; `Store.derive_label/1` is the shared first-user-message labeller.

### Headless MCP surface (external consumers)

The same descripex-annotated harness toolset is exposed as a spec-compliant **MCP server** on the same Bandit (`http://localhost:4018/harness/mcp`). The implementation is `Harness.Dashboard.MCPServer` (built on `anubis_mcp`, JSON-RPC 2.0 over Streamable HTTP via `Anubis.Server.Transport.StreamableHTTP.Plug`). `initialize` / `ping` / prompts / resources fall through to anubis's `@before_compile`-appended catch-all; harness overrides `tools/list` and `tools/call` to reuse `Harness.Chat.Tools` (the same registry + dispatcher the in-process chat loop calls).

`claude -p` (and any other MCP-aware orchestrator) wires into it via a standard `.mcp.json` HTTP transport entry:

```json
{
  "mcpServers": {
    "harness": {
      "type": "http",
      "url": "http://localhost:4018/harness/mcp"
    }
  }
}
```

When `Harness.Chat.Claude` spawns its backing `claude -p`, it writes exactly this config to a per-session `.harness-mcp-config.json` and passes it via `--mcp-config <path>`. External consumers point their own `.mcp.json` at the URL the same way.

**Only JSON-driveable tools are on the MCP/chat surface.** `Harness.Manifest.mcp_tools/1` rejects any tool with an `:exchange_data` param — a stateless JSON caller cannot construct an Elixir struct — so `supervisor-start_run`, the `batch-*` tools (`batch-dispatch` / `batch-run` / `batch-run_pinned` / `batch-run_evaluation`), `agent_evaluation-compare`, `audit_review-grade_fix_with`, and `project_registry-register` (takes a `%Project{}` — use the flat `dispatch-register_project` instead) are **excluded** from `tools/list`. They stay on the full Elixir driver surface (`Harness.Manifest.build/0` / `modules/0`, `project_eval`, IEx). Exposed JSON tools (the § "Primary Surface" list):

- **Dispatch:** `dispatch-task`, `dispatch-await`, `dispatch-recommend`, `dispatch-bundle`, `dispatch-compare`.
- **Observe / control a live run by `run_id`:** `dispatch-status`, `dispatch-transcript`, `dispatch-transcript_events`, `dispatch-cancel`, `dispatch-hold`, `dispatch-steer`, `dispatch-resume`.
- **Recover a settled run by `run_id`:** `dispatch-resume_failed` (re-dispatch a `:failed` task off its retained branch + failure report; same-agent or `escalate`), `dispatch-reland` (re-enqueue landing for a land-capped `blocked` task, zero tokens).
- **Settled-run detail:** `dispatch-verdict_detail` (the reviewer's verdict / report / ratings), `result_store-list_run_records`.
- **Agent KPIs / routing:** `result_store-aggregate_by_agent` (per-agent KPI rollup), `result_store-get_capability_score` / `result_store-list_capability_scores`, `dispatch-recommend`.
- **Roadmap / registry / recipes:** `roadmap-ingest` / `roadmap-list` / `roadmap-next_bundle` / `roadmap-ready` / `roadmap-mark_landed` / `roadmap-mark_blocked`, `project_registry-list` / `project_registry-lookup` / `dispatch-register_project`, `playbooks-list` / `playbooks-get`, `audit_review-grade_fix`.

The full annotated-surface inventory (what is reachable, what is intentionally in-process, and the judgment-free / in-run-isolation guarantees) lives in `docs/orchestrator-surface-inventory.md`.

The run-observe/control flat tools (`status` / `transcript` / `transcript_events` / `cancel` and the run-recovery trio `hold` / `steer` / `resume`) wrap `Harness.Run` functions whose `run :: String.t() | pid()` handle would otherwise mark them `:exchange_data`; the flat `run_id`-only wrappers (macro-generated via `Harness.Dispatch.RunTool` for the uniform `{:ok,_} | {:error,:not_found}` trio, hand-written for `cancel`'s bare `:ok` and for `hold`/`steer`/`resume` whose extra args + bare-`:ok` shapes diverge from the macro) are the JSON-native path that closes the live-observe-and-recover gap. `dispatch-bundle` / `dispatch-compare` / `dispatch-verdict_detail` are the JSON-native counterparts to the struct-only `batch-*` / `agent_evaluation-compare` / per-check-output ops, and `dispatch-register_project` is the scalar counterpart to the struct-taking `Harness.ProjectRegistry.register/1`.

**Flat dispatch — `dispatch-task`.** The struct-passing `roadmap-ingest` → `supervisor-start_run` two-step is not runnable over a stateless JSON boundary (the caller cannot hold the returned `%Harness.Roadmap.Item{}` between calls, and `start_run` takes `%Item{}` / `%Project{}` structs). `Harness.Dispatch.task/4` (tool `dispatch-task`) collapses the flow into one call taking only JSON scalars: `project_name` (registered project), `task` (id string or `"next"`), `adapter` (`recommend` default / `claude` / `codex` / `cursor` / `grok` / `antigravity` / `pi`), and `scrub_anthropic_key` (boolean, default `true` — strips `ANTHROPIC_API_KEY` so Claude dispatches use subscription OAuth). Every run is gated by the cross-family reviewer — there is no opt-out flag. The `recommend` adapter path ingests the task, reads its capability-domain tags, calls `dispatch-recommend`, and re-renders the prompt for the selected adapter before starting the run. Explicit adapter names bypass recommendation. It resolves the project, ingests the task (rendered natively for the chosen adapter — rmap renders all six), applies the scrub, and starts the supervised run with `subscriber: nil`, returning `{:ok, %{run_id: ...}}` or a structured `{:error, reason}`. An adapter harness can't run (e.g. `droid` — renderable by rmap, no harness adapter) rejects as `{:unknown_adapter, "droid"}`. Observe the run afterward by `run_id`. This is the chat/MCP replacement for the in-process Elixir `ingest` → `start_run` two-step, which stays canonical for `project_eval`/IEx.

**Routing advice — `dispatch-recommend`.** `Harness.Dispatch.recommend/2` takes a domain string (`"otp"`, `"ecto"`, `"liveview"`, etc.) and returns ranked advice: `strategy: :explore` for an unmeasured agent/domain cell, `:exploit` for the best measured score after stale-score discounting, or `:fallback_no_data` when the domain has no measurements at all. Stale scores are flagged and discounted, not deleted. The tool is advisory — callers can inspect the rationale and still choose a different adapter.

**Automatic task-status writeback on the Oban path (Task 131).** `dispatch-task` /
`dispatch-bundle` / `Batch.dispatch` run through `Harness.Run.Worker`, which **claims the
task `in_progress` on run start** (via `Harness.Roadmap.mark_in_progress/2`, best-effort: a
failed `rmap` writeback logs and continues, never fails the run) so the next cron tick's
`roadmap-ready` / `rmap next` no longer return it. An **approved-but-unlanded** run (under
`landing_policy: :manual`) *stays* `in_progress` — only an explicit land
(`roadmap-mark_landed`) advances it to `done`; this is what stops the
"completed re-dispatched every tick" loop. A **terminal-failure** run (including a
reviewer rejection) reverts the task to `pending` (`Harness.Roadmap.mark_pending/2`, not
`blocked` — `blocked` is the lander's terminal sink) so a later tick retries; transient
failures snooze without reverting. The **escape-hatch `start_run` path does NOT go through the Worker**, so it does
*not* auto-claim — claim manually with `rmap status <id> in_progress` (or `roadmap-mark_*`)
when driving via `project_eval`/IEx. Writeback owner is the run lifecycle, never the poller.

**Blocking dispatch — `dispatch-await`.** `Harness.Dispatch.await/5` (tool `dispatch-await`) is the awaiting variant of `dispatch-task`: same flat scalars (`project_name`, `task`, `adapter`, `scrub_anthropic_key`) plus a `timeout_ms` (default `1_800_000` = 30 min), but instead of returning a `run_id` to poll it **subscribes the calling process to the run and blocks until the run settles**, returning a compact verdict summary as the tool result — one call gets the answer, no poll loop. The summary is a map: `run_id`, `task_id`, `state` (`:done` / `:failed`), `reason`, `passed`, `agent_diff_size`, `reviewer_diff_size`, `worktree_path`, and `review` (`%{verdict, report, ratings}` — the raw transcript is deliberately dropped; read the `%Run.Result{}`/`LogRecord` for it). The wait is **bounded**: if `timeout_ms` elapses first it returns a structured `:timed_out` summary (`run_id`, `state: :timed_out`, `reason: :await_timeout`, `timeout_ms`) — the run is **not** cancelled and stays observable/cancelable via its `run_id`, so the tool never wedges. Dispatch-failure shapes (`unknown_adapter` / `unknown_project` / ingest / start_run errors) are identical to `dispatch-task`. Use `dispatch-await` when you want the reviewer's verdict in-band; use `dispatch-task` for fire-and-forget when you'll observe later.

**The two surfaces share the same source of truth.** `Harness.Chat.Tools` is the registry + dispatcher both `Harness.Chat.Session` and `Harness.Dashboard.MCPServer` reuse — adding or annotating a tool with `api()` (Tier 2, descripex) surfaces it in both surfaces simultaneously, no separate wrapper layer.

### Playbooks — orchestration recipes as tools

`Harness.Playbooks` exposes version-controlled markdown recipes — "dispatch a single task", "fan out a bundle", "A/B compare adapters", "audit-grade a fix" — as two tools on the same descripex/MCP surface:

- `playbooks-list` (`Harness.Playbooks.list/0`) → `[%{name, title, summary}]`, the catalog.
- `playbooks-get` (`Harness.Playbooks.get/1`) → `{:ok, %{name, title, summary, body}}` with the full markdown, or `{:error, {:unknown_playbook, name}}`.

A playbook body names the exact tools to call, in order, with the gotchas inline (secret scrubbing, adapter selection, reading the verdict). The orchestrator calls `playbooks-list` to discover what's available, `playbooks-get` to load a recipe, then executes it by calling the other harness tools. Bodies live in `priv/playbooks/<name>.md`, embedded at compile time — editing a recipe is a markdown edit + recompile, not a code change. The dashboard surfaces them as buttons that prefill the chat input (`run the <name> playbook for <project>`). Add a playbook: drop a `priv/playbooks/<slug>.md` file and add a `@catalog` entry in `Harness.Playbooks`.

### When to use which

| Surface | Use when |
|---|---|
| `dispatch-task` (flat MCP) | **Default dispatch.** Stateless JSON, one roadmap task fire-and-forget. Scalars only, returns a `run_id` you observe later. The JSON-surface replacement for the struct two-step. |
| `dispatch-await` (flat MCP) | Same dispatch, verdict **in-band** — blocks until settled (bounded by `timeout_ms`), returns a compact verdict summary instead of a `run_id` to poll. Tightens the loop to one call. |
| `dispatch-recommend` (flat MCP) | Ask harness which agent to use for a capability domain before dispatching. Returns ranked explore/exploit advice from persisted scores; does not start a run. |
| `dispatch-bundle` (flat MCP) | Fan out the **next bundle** of pending tasks at once — one Oban-backed job per task, per-project concurrency cap. Any of the six delegatable adapters (claude/codex/cursor/grok/antigravity/pi). |
| `dispatch-compare` (flat MCP) | **A/B one task across N adapters** in isolated worktrees; returns side-by-side per-adapter metrics. Blocks until all settle. All six executors. |
| `dispatch-status` / `dispatch-transcript` / `dispatch-transcript_events` (flat MCP) | **Observe a live run** by `run_id` — lifecycle snapshot or buffered/parsed transcript (with `seq` for delta polling). The JSON-native replacement for `Harness.Run.status/1` + the browser transcript pane. |
| `dispatch-cancel` (flat MCP) | **Kill an in-flight run** by `run_id` (idempotent). |
| `dispatch-verdict_detail` (flat MCP) | **Read the reviewer's verdict / report / ratings** after settle, by `run_id`, loaded from the persisted record. The report is the triage surface for a rejected run. |
| `Run.Supervisor.start_run/4` / `Batch.run/4` (escape hatch — `project_eval` / IEx) | You need struct-level control the flat tools don't expose — explicit `retry_policy`, `required_capabilities`, `adapter_opts`, an explicit `reviewer:` override, an ordered fail-over adapter list, or `subscriber: self()` from a long-lived BEAM. |
| `Driver.run/3` / `AuditReview.grade_fix/1` | A cheap one-shot agent invocation (probe, grade, A/B), no worktree/reviewer-gate lifecycle. `audit_review-grade_fix` is the flat default-pairing version. |
| `Chat.Session` + `Chat.Claude` | The operator (human or upstream LLM) drives harness in natural language and watches tool calls render in the dashboard — exploratory ops, status queries, free-form orchestration. The LLM picks which tools to call. |
| MCP endpoint at `/harness/mcp` | An **external** orchestrator (another Claude session, Cursor, Sprite, etc.) calls harness tools without being inside harness's BEAM. Standard MCP transport — same `.mcp.json` shape you'd use for any MCP server. This is what surfaces all the flat tools above. |
| `playbooks-list` / `playbooks-get` | You want a ready-made recipe for a common flow rather than assembling the tool sequence yourself. List the catalog, fetch the one that fits, follow it. |

---

## Recommended Patterns (copy these)

> These are the **escape-hatch** patterns — Elixir run through `project_eval` (`mcp__harness_eval__project_eval` in Context A, `mcp__tidewave__project_eval` in Context B). For the common dispatch/observe/triage loop, prefer the flat `mcp__harness__dispatch-*` tools (§ "Primary Surface") — `dispatch-task` + `dispatch-status` + `dispatch-verdict_detail` replace the two-eval dance below for everything except struct-level ops.

**Long-running dispatch from MCP eval (result-survives-eval-exit pattern):**

When you do drop to `project_eval` against the live `iex -S mix` node, the eval process is ephemeral — it exits as soon as the snippet returns — so `subscriber: self()` is wrong here (the subscriber would be dead before the run settles). The Run process records a `%Harness.Run.LogRecord{}` to `Harness.ResultStore` on settle regardless, so use the two-eval pattern (or just call `dispatch-task` and skip all of this):

```elixir
# EVAL 1 — dispatch. Eval process exits immediately; the run keeps going.
{:ok, project} = Harness.ProjectRegistry.lookup("myapp")
{:ok, item}    = Harness.Roadmap.ingest({:id, "<task-id>"}, project: project)

{:ok, run_id, _pid} =
  Harness.Run.Supervisor.start_run(
    item, project, Harness.AgentAdapter.Claude,
    subscriber: nil,                              # NOT self() — eval is ephemeral
    lifetime_timeout: 3_600_000,
    env: %{"ANTHROPIC_API_KEY" => false}          # force subscription OAuth
  )

run_id   # capture this — it's the only handle the next eval needs
```

```elixir
# EVAL 2 — observe. Run as needed; durable after settle.
case Harness.Run.status("<run-id>") do
  {:ok, status}        -> status                    # while alive (+ 5s linger)
  {:error, :not_found} ->
    {:ok, [rec]} = Harness.ResultStore.list_run_records(run_id: "<run-id>")
    rec                                             # %Harness.Run.LogRecord{}
end
```

Live transcript: open `http://localhost:4018/harness/runs/<run_id>` in the browser. LiveView is subscribed to `Phoenix.PubSub` topic `harness:run:<id>:transcript`, fed by `Driver.run/3`'s `:on_output` callback. The operator (human) usually has this open; you (driver) usually don't need it unless you're triaging.

> **LogRecord field coverage.** `%LogRecord{}` carries the reviewer's **verdict** (`:approve`/`:reject`), its **report** (`review_report`) + **ratings** (`review_ratings`), the **reviewer fix-diff size** (`reviewer_diff_size`), per-run `token_usage` (`%Harness.TokenUsage{}`, parsed from the transcript), and the full implementer transcript. To triage a rejected run just call `dispatch-verdict_detail(run_id)` (or read `rec.review_report` off the LogRecord) — the report is the reviewer's prose on what it found. There is no per-check stdout to dig through: the reviewer already ran the checks and judged them.

**Single delegation with explicit adapter choice (subscriber-IS-caller variant, mix-run / long-lived BEAM only):**

```elixir
{:ok, project} = Harness.ProjectRegistry.lookup("myapp")
{:ok, item}    = Harness.Roadmap.ingest(:next, project: project)
adapter        = pick_adapter_for_task(item)   # your logic (cost, capability, A/B, etc.)

{:ok, run_id, _pid} = Harness.Run.Supervisor.start_run(
  item, project, adapter,
  subscriber: self(),                          # only correct if `self()` outlives the run
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

**Same-task A/B agent evaluation (one item, N adapters):**

```elixir
{:ok, item} = Harness.Roadmap.ingest({:id, "33"}, project: project)

{:ok, comparison} = Harness.Batch.AgentEvaluation.compare(
  item,
  project,
  [Harness.AgentAdapter.Claude, Harness.AgentAdapter.Codex, Harness.AgentAdapter.Cursor],
  max_concurrency: 3
)

# comparison.entries — side-by-side per-adapter metrics (verdict :approve|:reject|nil,
# reviewer_diff_size, duration_ms, agent_diff_size, token_usage).
# token_usage (%Harness.TokenUsage{input, output, cache_read, cache_creation,
# total}) is the efficiency signal — did the adapter solve the task in 50k
# tokens or 500k? Nil fields when the wire format reported no usage. Metrics
# are additive; the reviewer's verdict stays binary approve/reject
# (reviewer_diff_size 0 = approved with zero reviewer fixes = first-attempt pass).
```

Lower-level pinned batch (same machinery, no comparison wrapper):

```elixir
{:ok, batch} = Harness.Batch.run_pinned(
  [{item, Harness.AgentAdapter.Claude}, {item, Harness.AgentAdapter.Codex}],
  project,
  max_concurrency: 2
)
```

**Cross-agent audit grade (HIGH-tier):**

```elixir
{:ok, %{verdict: v, outcome: o, grader: g}} =
  Harness.AuditReview.grade_fix(
    implementer: :claude,
    sha: "abc1234",
    cwd: "/Users/efries/_DATA/code/myapp",          # explicit in Context A
    prompt: "Review the diff at the commit. Emit <<<VERDICT:APPROVE>>> or <<<VERDICT:REJECT>>> on its own line at the end."
  )
```

**Cost-aware adapter selection (free-tier query, Task 54):**

```elixir
# Surface adapters whose dispatch consumes no metered quota (e.g. pi.dev with
# a local LLM). :metered is the conservative default for every other adapter.
adapters = [Harness.AgentAdapter.Pi, Harness.AgentAdapter.Claude]
[Harness.AgentAdapter.Pi] = Harness.AgentRegistry.filter_by_cost_tier(adapters, :free)

# Or via the generic capability surface:
true = Harness.AgentAdapter.supports?(Harness.AgentAdapter.Pi, {:cost_tier, :free})
```

`Harness.AgentRegistry.filter_by_cost_tier/2` is the cost-aware dispatch primitive — no selection policy is baked in. Compose with `available?/1` to also drop quota-exhausted adapters.

---

## Sharp Edges & Gotchas (2026-05 post-v0_5)

**Cross-checkout (Context A) specifics:**

- **Don't confuse the two MCP endpoints.** `mcp__tidewave__project_eval` runs inside *your repo's* BEAM (useful for inspecting your app's runtime state); `mcp__harness__project_eval` runs inside *harness's* `:4018` BEAM (this is the dispatch surface). Sending a `Harness.Run.Supervisor.start_run/4` call to your own Tidewave will fail with `undefined function` — harness modules aren't loaded there.
- **`.mcp.json` changes need a Claude Code restart.** New MCP servers aren't hot-reloaded into the running session — restart after editing.
- **`File.cwd!/0` is harness's cwd, not yours.** Inside an `mcp__harness__project_eval` snippet, any relative path resolves against `~/_DATA/code/harness/`, not `~/_DATA/code/myapp/`. Pass `:project` to `Roadmap.ingest/2` (carries `roadmap_path`), and pass explicit `cwd:` to `AuditReview.grade_fix/1` and ad-hoc `Driver.run/3` calls.
- **Project registration persists across BEAM restarts only via `config/dev.exs` or `config/dev.local.exs`.** A runtime `ProjectRegistry.register/1` is gone on the next `iex -S mix` boot. For ongoing work, edit one of those files (host-local registrations belong in the gitignored `dev.local.exs`) and ask the operator to restart.

**General (apply to both contexts):**

- **The native MCP surface is the primary one — `project_eval` is the escape hatch, not the other way round.** The flat tools are served by a spec-compliant MCP server (`Harness.Dashboard.MCPServer`, JSON-RPC 2.0 over Streamable HTTP at `/harness/mcp`) — you call them as ordinary `mcp__harness__<tool>` tools via the `.mcp.json` HTTP-transport entry, not via any bespoke `GET`/`POST` REST shape. Tidewave `project_eval` remains wired alongside it purely for ad-hoc Elixir inspection and the struct-surface ops the flat tools deliberately omit. If you find yourself writing `start_run`/`Batch`/`compare` snippets through `project_eval` for a routine dispatch, stop — there's a flat tool for it.
- **AgentRegistry is a soft hint, not a contract** (Task 40 resolved 2026-05-27 as option (b)). Unavailability state is in-memory only and clears on GenServer restart **by design** — the registry is a latency optimization to skip known-bad adapters at dispatch; correctness lives in Oban (workers map quota → `{:snooze, _}`, persisted job rows survive both restarts and quota windows). Bounded cost of a restart-clear: one wasted first-attempt per previously-marked-unavailable adapter. Don't trust quota state across BEAM restarts; do trust Oban retry. Also: Task 41 (Codex worktree-isolation regression) is **resolved as of 2026-05-27** — `codex exec --cd <cwd>` pins the working root at the exec level, mirroring the Task 32 fix shape. Full rationale: `Harness.AgentRegistry` `@moduledoc` § "Availability is a soft hint, not a contract".
- **Worktree isolation is enforced via capability + guard.** All shipped adapters currently declare `worktree_isolation: true`, so `Harness.Run` trusts the capability and skips the main-checkout pollution snapshot. The dispatch guard (`Harness.Worktree.Isolation`) still refuses to start a worktree-isolated run on any future non-isolating adapter, and `Isolation.check_pollution/3` remains available for explicit callers. Task 60 (2026-05-27) added a four-tier pollution allowlist (run opts → project → app config → `default_pollution_allowlist/0`) for those explicit pollution checks.
- **Renderable ≠ executable**: rmap renders for more agents than harness can run. All six harness adapters render natively (no two-step), but `droid` — renderable by rmap — has no harness adapter and rejects as `{:unknown_adapter, "droid"}` / `{:invalid_agent, :droid}`. Distinct from worktree isolation (see § "Renderable vs executable agents" above for both axes).
- **Results are delivered to the subscriber** but not automatically persisted beyond Oban job rows + the file-backed `ResultStore` `LogRecord` (Task 19). The `LogRecord` carries the implementer transcript AND the reviewer's verdict / report / ratings + fix-diff size — read it via `dispatch-verdict_detail` / `result_store-list_run_records`.
- **Cold worktrees are slow.** A fresh worktree has no `deps/` / `_build/` / dialyzer PLT — the implementer and reviewer each pay the cold-build cost. Budget timeouts accordingly.
- **Secret scrubbing**: Use the `:env` map with `false` values. Do this explicitly for any key that might shadow a subscription (classic `ANTHROPIC_API_KEY` shadowing Claude's OAuth case).

---

## When to Bypass Harness (rare)

Only for:
- Foundational scaffolding that changes harness's own supervision tree, dep stack, or Endpoint while the run lifecycle itself is in flux (the v0_5 precedent — dogfooding context only).
- True emergencies where the harness path is broken and you have filed the gap.

A new phase that only adds features on stable surfaces does **not** earn a hand-build window.

In the consuming-repo context (A), you never have "in-checkout" as an option — your own session isn't holding the harness BEAM. The bypass case there is "hand-edit `myapp` files directly without going through harness" — only valid for emergencies where harness can't dispatch and you've filed the blocker.

---

## Anti-Staleness Contract (for future maintainers and rmap tasks)

**This file must be updated when the driver surface or consumer setup changes.**

Changes that require an update to this skill:
- New or changed fields on `Harness.AgentAdapter.Invocation`
- New `rule_channel` values or rule injection behavior
- New public functions on `Harness.Run.Supervisor`, `Harness.Batch`, `Harness.Batch.AgentEvaluation`, `Harness.Roadmap`, `Harness.Dispatch`, `Harness.AgentAdapter.Driver`
- Changes to which `api()`-annotated functions are JSON-reachable vs. `:exchange_data`-filtered (the orchestrator surface) — keep `docs/orchestrator-surface-inventory.md` in sync
- New adapters or capability declarations
- Changes to the renderable-vs-executable contract (`@valid_agents`, the adapter registry) or recommended dispatch paths
- New result shapes or verdict semantics
- **Changes to project-registration config shape** (`config :harness, :projects, [...]`)
- **Changes to the `.mcp.json` shape Tidewave expects, or harness's dashboard port (`:4018`)**
- New or changed `Harness.Chat.Backend` callbacks, new backends, or changes to `Harness.Chat.Session`'s public surface (`start_link/2`, `user_message/3`, `snapshot/1`, `cancel/1`)
- Changes to chat persistence (`Harness.Chat.Store` `save/3` / `load/2` / `list/1` shapes, the `config :harness, :chat_store` key), `Harness.Chat.Supervisor.list_sessions/0`, or the `/harness/chat` `:index` route
- Changes to the MCP transport (`/harness/mcp` path, JSON-RPC envelope, tool naming, `Harness.Chat.Tools` registry shape)
- Additional MCP backends beyond `Harness.Chat.Claude` (if/when a library-backed metered-API backend lands as an opt-in)
- New or changed `Harness.Playbooks` (catalog entries, `priv/playbooks/*.md` recipes that drift from the actual tool surface, or the `list/0` / `get/1` shapes)

**How this skill reaches the orchestrator's context.**

- **Context A** (consuming repo): the consuming repo's `CLAUDE.md` imports it via `@~/_DATA/code/harness/skills/harness-driver/SKILL.md`. The skill is shared from the harness checkout; consuming repos do not vendor it.
- **Context B** (dogfooding): harness's own `CLAUDE.md` imports it via `@skills/harness-driver/SKILL.md` (relative).

Either way it does not auto-load on its own — the CLAUDE.md import is what brings it into session context.

When in doubt, read the current moduledocs for `Harness.AgentAdapter`, `Harness.Run`, `Harness.Batch`, `Harness.ProjectRegistry`, and `Harness.Roadmap`, then make this skill match reality. Tidewave `project_eval` is the fastest verifier: `function_exported?/3`, `__info__(:functions)`, `Map.keys(Struct.__struct__())`, and `get_docs` will catch most drift in seconds.

---

## Related Canonical Documents

- `README.md` § "Use harness from another repo" (the human-facing onboarding for Context A)
- `CLAUDE.md` § "Dogfooding — harness Builds harness" (policy)
- `@~/.claude/includes/harness-workflow.md` (portfolio harness workflow contract + verdict table; layered on workflow-philosophy etc)
- `docs/dogfooding-workflow.md` (harness-incubator runbook + full driver script template + batch log)
- `docs/agent-cli-reference.md` (per-agent headless facts)
- `ROADMAP.md` (current phase and open tasks)

Load those in addition to this skill when doing deep harness orchestration work.

---

**This skill is the thing an AI should load first when it finds itself in a context where harness is available as a delegation engine** — whether that's because it's running inside the harness checkout itself (Context B) or because its consuming repo has been wired up to drive harness (Context A).

Use it. Keep it accurate. Dispatch through harness.
