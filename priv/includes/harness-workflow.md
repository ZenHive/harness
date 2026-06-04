## Harness Workflow

OTP-native **delegate → verify → repair → land** loop for roadmap-driven development. An AI orchestrator drives harness; harness dispatches headless agents into isolated git worktrees, grades their work with the **target project's own check stack**, and optionally lands green deliverables onto the target branch.

**Promoted from** `docs/dogfooding-workflow.md` in the harness repo — that file remains the **incubator runbook** for harness-specific history, driver-script templates, and per-batch run logs. This include is the **portfolio-wide contract**. Version-controlled source: `priv/includes/harness-workflow.md` in the harness repo; install to `~/.claude/includes/harness-workflow.md` via `mix harness.install_includes`.

### Relationship to Other Includes (Layered — No Supersession)

| Include | Role relative to harness-workflow |
|---|---|
| `workflow-philosophy.md` | **Foundation.** Evaluator separation, session-per-phase, verification-before-completion. Harness automates the loop while preserving these principles — the verification stack is the grader, never the agent's self-report. |
| `task-prioritization.md` | **Task selection.** D/B/U scoring, `rmap next`, parallel markers, refine-don't-duplicate. Harness executes whatever rmap returns; it does not replace prioritization. |
| `worktree-workflow.md` | **Manual parallel sessions.** For hand-build work outside harness dispatch — operator-created worktrees, PR flow, post-merge audit. Harness manages its own per-run worktrees (`harness/<run-id>`); manual worktree rules still apply for hand-build sessions. |
| `dev-lifecycle.md` | **Manual five-phase chain** (`task-driver → worktree → bots → merge → audit-review`). Use when *not* driving through harness. Harness is the automated alternative for dispatchable roadmap tasks; dev-lifecycle still governs plan-and-file, pre-commit review, and post-merge audit. |
| `agent-dispatch.md` / cloud-delegation stack | **Linear/Codex/Cursor PR delegation** without a running harness BEAM. Orthogonal path — projects can use cloud delegation *or* harness; harness subsumes the dispatch+verify loop when the OTP node is running. |
| `skills/harness-driver/SKILL.md` (harness repo) | **API surface contract** — MCP tools, `project_eval` patterns, `%LogRecord{}` fields, sharp edges. Load on demand when driving harness; this include covers *workflow*, the skill covers *surfaces*. |

**Adopt per repo:** `@~/.claude/includes/harness-workflow.md` in the project's `CLAUDE.md` (load-on-demand row — not eager; same pattern as `workflow-philosophy.md`).

### The Loop

```
rmap task → dispatch headless agent → commit to harness/<run-id> → run check stack → verdict
                │                                              │
                └──────── repair loop (red → feed failures → re-dispatch) ──┘
                └──────── lander (green + auto policy → ff-merge + re-verify + push) ──┘
```

One run = one supervised `Harness.Run` gen_statem: fork worktree off target `HEAD`, dispatch agent, commit diff to `harness/<run-id>`, run verification, settle `:done` or `:failed`. **Success = verification green**, never agent exit code or self-report. Projects with auto-landing also run a **cross-family semantic gate** on green verdicts (opposite-model-family grader approves diff against acceptance criteria) before settle — REJECT feeds the repair loop (`:semantic_rejection`).

### When to Dispatch vs Hand-Build

**Default: dispatch every pending rmap task whose dependencies are satisfied.** Hand-build only what harness cannot yet do:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the verification stack itself is in flux**
- Tiny tasks — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change
- UI / LiveView / heex / CSS — headless agents idle-timeout without visual reward; use tidewave + browser
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around by hand-building

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch__task` (fire-and-forget) or `dispatch__await` (blocks until settle) against `http://localhost:4018/harness/mcp`. Observe in-flight runs via `dispatch__status`, `dispatch__transcript`, `dispatch__verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full per-failed-check stdout/stderr to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. Antigravity declares `worktree_isolation: false` and is rejected for worktree-isolated runs.

### Reading the Verdict

| `state` / `reason` | Meaning | Action |
|---|---|---|
| `:done` | Verification green. | Deliverable on `harness/<run-id>`. Review diff, integrate (or let auto-lander handle it), `rmap status <id> done`. |
| `:failed` / `:verification_red` | Agent work failed ≥1 check. | Inspect `dispatch__verdict_detail` / `check_output`. Repair loop may auto-resume; else re-dispatch. Supervised failure, not a harness bug. |
| `:failed` / `:semantic_rejection` | Semantic gate rejected a green check-stack verdict. | Read grader transcript. Repair loop may auto-resume; else re-dispatch. Supervised failure, not a harness bug. |
| `:failed` / `:no_changes` | No diff produced. | Read transcript. Billing/auth → environment fix + re-run. Harness spawn failure → harness bug (`rmap new`). Genuine no-op → re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` `{:verification_failed,_}` `{:verifier_crashed,_}` | Harness-side failure. | **Harness bug.** File via `rmap new`. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside run worktree into main checkout. | Agent/adapter issue. Harness trapped correctly. Re-dispatch with worktree-honoring adapter. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | Post-run pollution `git status` errored. | Rare; transient git/IO issue. Re-run; if persistent inspect main checkout git state. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` or investigate hang. |

Red runs retain the worktree at `result.worktree_path` for inspection. Green runs keep branch `harness/<run-id>` after worktree teardown.

### Parallel Dispatch

`Harness.Run.Supervisor` is a `DynamicSupervisor` — N crash-isolated runs, each with its own worktree.

- **Batch by dependency graph** — every pending task whose `depends_on` is satisfied. Each rmap task is sized for ~one session; harness fans those sessions out in parallel.
- **Mix adapters deliberately** — rotate Claude / Codex / Cursor / Grok / Antigravity / Pi for coverage; excluding an adapter from a batch is training-comfort bias, not a real constraint (Antigravity excepted: no worktree isolation).
- **Same-file is fine; same-function is not.** Two tasks rewriting the same function guarantees un-auto-mergable collision — dispatch sequentially or fold into one rmap task (`task-prioritization.md` § "Refine, Don't Duplicate").
- **One driver BEAM** for all concurrent runs in a wave.
- **Integration order (manual landing):** bring smallest/isolated diffs onto target first; rebase siblings; re-run verification on target after last merge.
- **While a wave is in flight:** do not run `rmap status` / `rmap mark` / `rmap new` in parallel sessions against the same checkout — triggers `:checkout_polluted` false-positive.

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch` skip manual merge:

1. Green run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` ff-merges onto `origin/<target>` (rebasing if target moved)
3. **Re-verifies the integrated state**
4. ff-pushes verified tip; advances rmap (`done --verified --shipped-in <sha>`)

Conflict / post-merge-red / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

Per-project landing policy lives in `%Harness.Project{}` config — default `:manual` unless opted in.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink type grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **Verification preset mirrors project bar.** Opt into `:elixir_precommit` (or project-specific stack) when a green harness verdict must imply the project's own `mix precommit` would pass — lighter presets are for faster iteration.

### Known Sharp Edges

- **Fresh worktrees lack `deps/` / `_build/`.** Agent must run project bootstrap (e.g. `mix deps.get`) or verification fails at compile — file harness gaps via `rmap new`.
- **Strict grader.** Missing `@doc`, credo findings, coverage below threshold → red. Expect repair cycles.
- **Cold dialyzer PLT** dominates first-run verification time in Elixir worktrees.
- **Nested Claude auth.** `ANTHROPIC_API_KEY` shadows subscription OAuth — scrub per run (`scrub_anthropic_key: true` or `env: %{"ANTHROPIC_API_KEY" => false}`).
- **`dispatch__verdict_detail` for triage.** Failed-check stdout/stderr is persisted on `%LogRecord{}` — no re-run needed for credo/test/sobelow output.
- **MCP observe path.** Prefer `dispatch__status` / `dispatch__verdict_detail` over raw `ResultStore` map filters (MCP serializes keyword args as maps).

### Repo-Specific Detail

| Need | Where |
|---|---|
| Harness API surfaces, MCP tool shapes | `skills/harness-driver/SKILL.md` in harness repo |
| Driver script template, cutover history, run log | `docs/dogfooding-workflow.md` in harness repo |
| Cross-checkout consumer setup | `skills/harness-driver/SKILL.md` § "Context A" |
| D/B/U scoring, task writing | `task-prioritization.md`, `task-writing.md` |
| Manual session/PR/audit chain | `dev-lifecycle.md`, `worktree-workflow.md` |
