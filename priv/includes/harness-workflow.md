## Harness Workflow

OTP-native **implement → review → land** loop for roadmap-driven development. An AI orchestrator drives harness; harness dispatches headless implementer agents into isolated git worktrees, then a **cross-family reviewer AI** gates every deliverable (runs the project's checks itself, fixes inline, writes `.harness/review.json`). Optional auto-landing ff-merges approved work; a post-merge audit agent sweeps hygiene.

**Promoted from** `docs/dogfooding-workflow.md` in the harness repo — that file remains the **incubator runbook** for harness-specific history, driver-script templates, and per-batch run logs. This include is the **portfolio-wide contract**. Version-controlled source: `priv/includes/harness-workflow.md` in the harness repo; install to `~/.claude/includes/harness-workflow.md` via `mix harness.install_includes`.

### Relationship to Other Includes (Layered — No Supersession)

| Include | Role relative to harness-workflow |
|---|---|
| `workflow-philosophy.md` | **Foundation.** Evaluator separation, session-per-phase, verification-before-completion. Harness automates the loop while preserving these principles — the **reviewer AI** is the grader, never the implementer's self-report. |
| `task-prioritization.md` | **Task selection.** D/B/U scoring, `rmap next`, parallel markers, refine-don't-duplicate. Harness executes whatever rmap returns; it does not replace prioritization. |
| `worktree-workflow.md` | **Manual parallel sessions.** For hand-build work outside harness dispatch — operator-created worktrees, PR flow, post-merge audit. Harness manages its own per-run worktrees (`harness/<run-id>`); manual worktree rules still apply for hand-build sessions. |
| `dev-lifecycle.md` | **Manual five-phase chain** (`task-driver → worktree → bots → merge → audit-review`). Use when *not* driving through harness. Harness is the automated alternative for dispatchable roadmap tasks; dev-lifecycle still governs plan-and-file, pre-commit review, and post-merge audit. |
| `agent-dispatch.md` / cloud-delegation stack | **Linear/Codex/Cursor PR delegation** without a running harness BEAM. Orthogonal path — projects can use cloud delegation *or* harness; harness subsumes the dispatch+review loop when the OTP node is running. |
| `skills/harness-driver/SKILL.md` (harness repo) | **API surface contract** — MCP tools, `project_eval` patterns, `%LogRecord{}` fields, sharp edges. Load on demand when driving harness; this include covers *workflow*, the skill covers *surfaces*. |

**Adopt per repo:** `@~/.claude/includes/harness-workflow.md` in the project's `CLAUDE.md` (load-on-demand row — not eager; same pattern as `workflow-philosophy.md`).

### The Loop

```
rmap task → implementer AI (worktree) → commit harness/<run-id> → reviewer AI (THE GATE) → done | failed
                                                                              ↓ (done + auto policy)
                                                              MERGE (lander: rebase + ff-push, no re-verify)
                                                                              ↓
                                                              AUDIT (post-merge audit agent, best-effort)
```

One run = one supervised `Harness.Run` gen_statem: fork worktree off target `HEAD`, dispatch implementer, commit diff to `harness/<run-id>`, dispatch cross-family reviewer into the same worktree. The reviewer runs the project's `check_command` hint, fixes what it can, writes `.harness/review.json`. **Success = reviewer `approve`** — never implementer exit code or self-report. There is **no mechanical verification gate** in harness; judgment lives in agents.

Rejections put the task back in the queue for re-dispatch. Fix-and-approve is the near-absolute default for the reviewer.

### When to Dispatch vs Hand-Build

**Default: dispatch every pending rmap task whose dependencies are satisfied.** Hand-build only what harness cannot yet do:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**
- Tiny tasks — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change
- UI / LiveView / heex / CSS — headless agents idle-timeout without visual reward; use tidewave + browser
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around by hand-building

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch-task` (fire-and-forget) or `dispatch-await` (blocks until settle) against `http://localhost:4018/harness/mcp`. Observe via `dispatch-status`, `dispatch-transcript`, `dispatch-verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full transcript + reviewer report to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**In-flight idempotency (Task 286):** a second `dispatch-task` / `dispatch-bundle` of the same `{project, task_id}` while a non-terminal run exists returns the **existing** `run_id` (Oban `conflict?: true`), not a duplicate — a retried dispatch is safe and free.

**Write-set serialization (Task 292):** `dispatch-bundle` and cron ready-set dispatch compute each task's `touches ∪ files_to_modify` before enqueue. Tasks with overlapping write-sets are logged and serialized into later waves instead of fanned out together. Callers no longer hand-dedupe ready sets; they must keep `touches` / `files_to_modify` accurate because harness does not infer paths from task prose.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. All six shipped adapters declare `worktree_isolation: true`.

### Routing & Model Management

- **Resolve `assignee` + `model` from facts, not by reading code.** `routing-brief` is the thin task-writer index: dispatchable agent roster, each agent's standing model (`Config.agent_model/1`), model availability/blocks, and per-agent KPI rollups — every metric carries `n`, no ranking. A model-capable agent with no configured model shows `model: nil, model_required: true`.
- **Scout routing (advisory).** `dispatch-recommend` returns the cross-family scout AI's per-facet `:exploit` pick (with rationale) or a safe `:explore` / `:fallback_no_data` when a facet is unmeasured; `dispatch-assess_facets` forces a fresh scout assessment. The caller decides whether to dispatch the pick — legacy composite scores are not used for routing.
- **Model is required, never defaulted.** Implementer precedence: **task `model` → `{:agent_model, agent}` → REJECT** (`{:model_required, agent}`) — harness never falls through to the CLI's ambient default. The **reviewer has no task-pin axis**: its model comes solely from `{:agent_model, agent}` for the reviewer adapter's agent (`Run.reviewer_model/1`), and a model-capable reviewer with no configured model is rejected *before* the reviewer spawns. `antigravity` (no `--model` flag) is the lone model-incapable exemption.
- **Block exhausted premium models.** A monthly budget can exhaust (e.g. cursor-Opus) while harness still lists the pair as available and routes to it. `model_availability-block_model` (with a `blocked_until` window) removes the pair from routing/cron; `model_availability-unblock_model` clears it.
- **Cost-aware A/B.** `dispatch-compare` runs one task across N adapters (optional per-adapter model overrides) and returns per-adapter `verdict` / `reviewer_diff_size` / `duration_ms` / `token_usage` for selection.

### Reading the Verdict

| `state` / `reason` | Meaning | Action |
|---|---|---|
| `:done` / `:approved` | Reviewer AI approved (possibly after inline fixes — check `reviewer_diff_size`). | Deliverable on `harness/<run-id>`. Review diff, integrate (or let auto-lander handle it), `rmap status <id> done`. |
| `:failed` / `{:review_rejected, report}` | Reviewer rejected (degenerate — near-never by design). | Read `report`. Task back in queue; re-dispatch. |
| `:failed` / `{:review_stuck, report}` | No verdict: reviewer unavailable, crashed, or missing/malformed `.harness/review.json`. | Read `report`. Fix environment or re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` | Harness-side mechanical failure. | **Harness bug.** File via `rmap new`. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside the run worktree into the main checkout — surfaces as `:failed` **only after bounded AI recovery was exhausted** (see "Self-healing recovery" below). | Recovery declared the run dead. Likely an agent/adapter isolation issue; re-dispatch with a worktree-honoring adapter. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | Post-run pollution `git status` errored. | Rare; transient git/IO. Re-run; inspect checkout if persistent. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` or investigate hang. |
| run process **crashed** (no settle) | gen_statem died. | **Harness bug.** File via `rmap new`. |

Failed runs retain the worktree at `result.worktree_path` for inspection. Approved runs keep branch `harness/<run-id>` after worktree teardown. Use `dispatch-verdict_detail` for the reviewer report, ratings, and `reviewer_diff_size` — no mechanical per-check stdout.

**The verdict artifact** `.harness/review.json` is `{verdict, report, facets, skills, ratings}`: `verdict` (`approve`/`reject`) is the gate; `report` is the reviewer's prose; **`facets`** (open-vocabulary routing KEY — the kind of task) and **`skills`** (v0_13 two-axis rubric, routing VALUE) feed per-facet capability routing; `ratings` is the legacy flat-score fallback. It lives under `.harness/` (excluded from staging) so it never rides in the deliverable commit.

**Self-healing recovery (the `:recovering` state).** Before settling `:failed` for an *interpretive* non-rejection failure — checkout pollution is currently the one wired call-site — the run spawns a **bounded cross-family recovery AI** (`:recovering` state, budget 1/run) with minimal context (the error term + the main checkout's `git status` + the implementer transcript tail + the failing-check output, never the full transcript). It writes `.harness/recovery.json` `{outcome: "repaired"|"dead", report, repaired}`; harness reads it mechanically and **decides nothing itself**: `repaired` resumes at `:committing` and **re-runs the reviewer gate** (never skips to `:done`); `dead` / missing / malformed settles `:failed` with the original reason. A genuine `verdict: reject` is never routed through recovery. The `Result` carries `recovery_attempts` / `recovery_outcome` / `recovery_repaired` / `recovery_token_usage`. (Tier-1 mechanical self-heal precedes it: the reviewer is re-prompted once on a missing/malformed `review.json` — `reviewer_reprompt_count`, capped at 1 — and rotates to the next cross-family candidate on a reviewer timeout — `reviewer_rotation_count`.)

### 🚨 Recover, Don't Redo — Never Burn Tokens Re-Implementing Committed Work

**A run that committed to `harness/<run-id>` already paid for the implementer. Recovering that branch costs a fraction of a fresh dispatch — re-dispatching from `pending` throws the work away and makes the agent redo all of it.** The reflex to "reset → pending → dispatch again" is a token bonfire whenever a retained branch with commits exists. Check for the branch *first*; pick the cheapest primitive that fits:

| Run state — committed `harness/<run-id>` branch exists | Recover with | Agent tokens |
|---|---|---|
| Approved but unlanded (land-cap, lander crash) | `dispatch-reland` | **zero** — pure git rebase + push |
| Committed, review-stage failure (work is good) | `dispatch-rereview` | zero implementer — re-enters at the reviewer gate |
| Committed, implement-stage incomplete/`:failed` | `dispatch-resume_failed` (`escalate: true` to re-route agent) | **re-spends implementer tokens** — a fresh implementer invocation branched off the retained commits with the failure report injected (contrast `rereview`, which re-runs only the reviewer) |
| Live `:held` run (paused, not dead) | `dispatch-resume` | none — un-pauses in place |
| **No commits / no retained branch** | reset → `pending` + fresh `dispatch-task` | full redo — **the only case where this is correct** |

**Live-run intervention (not recovery of a dead run):** `dispatch-hold` (optionally `interrupt: true`) parks a live run mid-turn, `dispatch-steer` stashes guidance applied on resume, `dispatch-resume` un-pauses in place, `dispatch-cancel` kills it (idempotent). Use hold → steer → resume to force-hand a grinding implementer to the reviewer gate instead of burning the lifetime budget.

**The gate before any reset-to-pending + re-dispatch:** `git branch -a | grep harness/<run-id>` and `git log --oneline origin/<target>..harness/<run-id>`. Commits present ⇒ recover, never redo.

**🚨 First, confirm the run actually *didn't* land — check `origin`, not your local checkout.** Under `landing_policy: :auto` the lander pushes to `origin/<target>` and **deliberately never touches your local checkout** (it ff-pushes from a detached worktree). So after an autonomous land your local `tasks.toml` is **stale**: it still reads `in_progress` for a task the lander already marked `done --shipped-in` on origin. **Reading that stale local status as "the run didn't land" is the trap** — it triggers a wasteful reset-to-`pending` + re-dispatch that *duplicate-lands already-shipped work*. Before concluding anything from task status, `git fetch origin <target> && git rebase origin/<target>` (the existing "Sync development before committing" rule) or read ground truth directly:
- `git log --oneline origin/<target>` — does it already show `task <id> -> done (shipped …)` and the agent-delivery commit? Then it **landed**; your local view was just behind. Do nothing but rebase.
- `dispatch-status <run-id>` / `result_store-list_run_records run_id:<id>` — a record with `state: done, verdict: approve` means the run succeeded; cross-check landing against origin before touching the roadmap.

> **Observed 2026-06-12 (the cautionary tale this section exists for):** three approved runs (246/249/251) landed cleanly to `origin/development` — `done --shipped-in`, audited. But the operator's local checkout hadn't rebased, so `rmap show` read stale `in_progress`. That was misread as "approved but didn't land," the tasks were reset to `pending` and re-dispatched, and task 246 **landed a second time** (duplicate delivery) before the mistake surfaced. Root cause: reading stale local state instead of rebasing on `origin` first. The lander was working perfectly the whole time.

The recovery primitives (`reland`/`rereview`/`resume_failed`) read the persisted `ResultStore` record, which **survives** worktree teardown and node restarts — so a genuinely approved-but-unlanded run (lander hit its land-cap, or a real rebase conflict retained the branch) is recoverable token-free via `dispatch-reland`. Reserve reset-to-`pending` for runs with **no committed branch and no settled record** — and only after confirming against `origin` that the work isn't already shipped.

### Parallel Dispatch

`Harness.Run.Supervisor` is a `DynamicSupervisor` — N crash-isolated runs, each with its own worktree.

- **Batch by dependency graph, then write-set.** Every pending task whose `depends_on` is satisfied can enter the ready set, but harness dispatches only the first wave whose `touches ∪ files_to_modify` are disjoint. Overlapping tasks wait for a later wave after the landed base moves forward.
- **Keep write-set fields accurate.** The dispatcher counts declared path intersections; it does not infer paths from the task body. If two tasks really edit the same function, either let write-set serialization sequence them or fold the coupled work into one rmap task (`task-prioritization.md` § "Refine, Don't Duplicate").
- **One driver BEAM** for all concurrent runs in a wave.
- **Integration order (manual landing):** smallest/isolated diffs onto target first; rebase siblings; run the project's check command on target after last merge.
- **While a wave is in flight:** do not run `rmap status` / `rmap mark` / `rmap new` in parallel sessions against the same checkout — triggers `:checkout_polluted` false-positive.

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch`:

1. Approved run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` rebases `harness/<run-id>` onto `origin/<target>` in a detached worktree
3. **ff-pushes without re-verification** — the reviewer already gated the work
4. Successful push enqueues post-merge audit; advances rmap (`done --verified --shipped-in <sha>`)

Conflict / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

**Cron manual-approval mode.** A per-project cron poller in `:auto` mode dispatches unattended; in `:manual` mode it **parks** each dispatch decision instead of enqueuing — drain the parked decisions with `dispatch-pending` and approve them with `dispatch-approve`, keeping the orchestrator in the loop for autonomous polling.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **`check_command` is a hint to the reviewer.** Free text (e.g. `"mix precommit.full"`) — the reviewer runs and judges it; harness does not execute it mechanically.
- **The cross-family reviewer reads `AGENTS.md`, not your Claude skills/includes.** `AGENTS.md` is generated from `CLAUDE.md` by `claude-marketplace/scripts/sync-agents-md.sh`, which recursively inlines every `@`-import. **Regenerate it after any `CLAUDE.md` change** (`bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh`, or `--dry-run` to preview) so the reviewer gates against current rules — a stale `AGENTS.md` makes codex/cursor/grok judge against rules you've already changed. **`--check` is the freshness gate** — it re-renders in memory and exits non-zero if `AGENTS.md` has drifted (diffs rendered output, not mtimes, so it catches drift in transitive `@`-imports too); wire it into CI / a pre-commit hook / the `check_command` so staleness fails loudly instead of silently. Consequence under Opus-4.8 skill-on-demand: once `CLAUDE.md` slims to the eager floor, reviewer-critical facts that *were* carried by eager includes (the `check_command` gate; that `mix test.json` / `mix dialyzer.json` emit JSON **by design** — parse for real failures, never flag the envelope; plain `mix dialyzer` is authoritative when the JSON encoder can't serialize a warning) no longer reach `AGENTS.md` via those imports. Put them in a **self-contained `## Toolchain & check commands` section in `CLAUDE.md`** so they survive the slim-down and flow into `AGENTS.md` on regen (ref: `tapakly/CLAUDE.md`, `ccxt_extract/CLAUDE.md`).
- **Delegation roster — opus last, and don't over-default to codex.** When assigning a dispatchable task to a harness adapter, prefer the external agents — **cursor, codex, grok** — and reserve the **claude/opus** adapter for work that genuinely needs it (harness-surface changes, judgment-heavy review, tasks the cheaper adapters keep bouncing). Opus tokens are precious: spend them last, not by default. Mix adapters across a wave for review coverage. A repo may override the roster in its own CLAUDE.md.
  - **Observed failure mode: reflex-routing everything to `codex`.** Run ledgers skew heavily codex-over-cursor/grok. Actively spread `assignee` across all three; reserve codex for tasks it's genuinely scored best on, not as the default.
  - **`cursor` runs on `composer-2.5-fast` by default — and that's the data-backed pick.** Pin `model = "composer-2.5-fast"` for cursor work: it's the cheapest cost-to-green in the ledger, and **every cursor capability KPI is measured on Composer** (it's a multi-model front-end, but the scores you'd route on reflect Composer, not whatever you pin). A heavier cursor model exists (`cursor-agent --list-models` lists `claude-opus-4-8-thinking-high` etc.) but is **not** the default and carries **no** capability data — pinning it *claims performance the ledger doesn't show*, so reach for it only with a concrete, named reason, not as the "design-heavy/Opus-grade" reflex. Model IDs churn; confirm with `cursor-agent --list-models`. **`model` is REQUIRED at creation for any non-`human` assignee** (`rmap new` rejects a model-less dispatchable task — "a dispatchable task must pin the LLM it runs on"; see `rmap.md` § "Pinning an LLM model"); "leave `model` unset for the agent default" does NOT work. Set `assignee` **and** `model` at task creation per `rmap.md`.

### Known Sharp Edges

- **Fresh worktrees lack `deps/` / `_build/`.** Implementer and reviewer each run project bootstrap (e.g. `mix deps.get`) when needed — budget timeouts for cold worktrees.
- **Reviewer runs the checks.** No mechanical check stack. Correct-but-not-pristine work → reviewer fixes and approves (`reviewer_diff_size` > 0).
- **Cold dialyzer PLT** dominates first reviewer check run in Elixir worktrees.
- **Nested Claude auth.** `ANTHROPIC_API_KEY` shadows subscription OAuth — scrub per run (`scrub_anthropic_key: true` or `env: %{"ANTHROPIC_API_KEY" => false}`).
- **Parallel-session rmap mutations** during a run can false-positive `:checkout_polluted` — wait for the wave or use a separate worktree.

### Repo-Specific Detail

| Need | Where |
|---|---|
| Harness API surfaces, MCP tool shapes | `skills/harness-driver/SKILL.md` in harness repo |
| Driver script template, cutover history, run log | `docs/dogfooding-workflow.md` in harness repo |
| Agent-gate architecture spec | `docs/agent-gate-workflow.md` in harness repo |
| Cross-checkout consumer setup | `skills/harness-driver/SKILL.md` § "Context A" |
| D/B/U scoring, task writing | `task-prioritization.md`, `task-writing.md` |
| Manual session/PR/audit chain | `dev-lifecycle.md`, `worktree-workflow.md` |
