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

**🚨 "Cross-family" is routing doctrine, not a mechanical guarantee.** Harness excludes only the *identical* agent from the reviewer slate (`Harness.Agents.reviewers/1` → `reject_implementer/2`); there is **no family concept in harness code**, so a `cursor` implementer can draw a `grok` reviewer even though both run SpaceXAI weights. The orchestrator owns the separation when it matters. This is deliberate, not an oversight: measured 2026-08-23 over 1,627 harness reviews, controlling for reviewer identity leaves no per-pair signal — review intervention is a **per-reviewer** trait (median `reviewer_diff_size`: Codex 96, Cursor 4, Claude 1, Grok 0), and the most capable reviewer in the ledger finds median 0 in the same work a heavier reviewer rewrites. Don't add a family scheduler to make the code match the older wording.

### When to Dispatch vs Hand-Build

**An rmap task is not automatically a harness run.** Dispatch only when the full
implement→review→land cycle buys meaningful safety, independent verification, or
parallel throughput. Historical run cost stays material even for D≤2 work, so the
old D≤2 / 30-LOC conjunctive exception was too narrow.

**Work inline by default when it is bounded and local:** one coherent surface,
typically D≤4, roughly ≤100 LOC across ≤5 files, focused-testable, and no positive
dispatch trigger below. These are routing hints, not an ALL-of gate — a risky D2
task can earn dispatch, while a routine D4 task can stay inline.

Positive dispatch triggers:

- Signing, money handling, cryptography, security, or authorization
- A public API/schema/contract change or a migration
- Harness runtime, CI/check infrastructure, or a repo-wide invariant
- Live/external-system semantics that need independent evidence
- Multiple subsystems, or genuinely useful parallel execution

Hand-build when harness cannot perform or judge the work:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**
- Work requiring live human/browser judgment, such as exploratory visual identity; routine spec-anchored UI remains dispatchable
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around the gap inside the target task

**🚨 The routing gate fires at `assignee =`, not at dispatch time.** rmap requires `assignee` + `model` at task creation, so the inline-vs-dispatch decision is made — and frozen — the moment the task is filed: a task carrying an agent assignee reads as "routing already decided" to every later session, and this section never gets consulted again. Two rules close that hole:

- **Filing a task: run this section BEFORE typing `assignee` — and a FILED task defaults to an agent.** The inline-vs-dispatch question above governs work you can execute *now*: inline-doable work is done inline and never filed. A task that reaches filing is cross-session by definition, so default-route it to a dispatch agent with a pinned `model` (roster spread per § "Delegation roster"); `assignee = "human"` must be earned by a hand-build reason named in the body — an operator-gated step (license, credential, purchase), no-spec visual identity, harness-loop-in-flux, or the user claiming the work. (Flipped 2026-08-13 from the old default-`human` rule after trading_dashboard tasks 86/87 — both dispatchable — were filed `human` by reflex. The ccxt_client-470 lesson survives with its real moral: a D2 one-file fix should be *done inline*, not filed at all — the filing was the defect, not the assignee.) Mirrored as question 6 of `task-writing.md`'s Pre-Creation Gate.
- **Reviewer `proposed_tasks` carry no routing authority.** Proposals arrive dispatch-shaped (suggested scores/markers), but the orchestrator owns routing the same way it owns filing — re-route each proposal through this gate instead of inheriting dispatchability from its shape. Sibling of task-writing's "Re-Generalize an Agent's Decomposition": that filters whose *architecture* a task encodes; this filters whose *routing* it encodes.

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch-task` (fire-and-forget) against `http://localhost:4018/harness/mcp`; wait for the wave by watching `origin/<target>` for the lander's commits, never by blocking on `dispatch-await` / `dispatch-await_runs` (§ "Never block on `dispatch-await*`"). Observe via `dispatch-status`, `dispatch-transcript`, `dispatch-verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full transcript + reviewer report to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**In-flight idempotency (Task 286):** a second `dispatch-task` / `dispatch-bundle` of the same `{project, task_id}` while a non-terminal run exists returns the **existing** `run_id` (Oban `conflict?: true`), not a duplicate — a retried dispatch is safe and free.

**Coalesce small related tasks:** `dispatch-coalesce` accepts an explicit task-id list and runs it as one worktree, implementer invocation, reviewer gate, and landing unit. Use it when small tasks share a bundle/surface and separating them would only repeat fixed run costs; keep independent tasks in `dispatch-bundle` so write-disjoint work still parallelizes. Coalesced members share the same landing SHA and never partially land — the reviewer must mark every member `approved` in the verdict's `task_outcomes` or the run fails as a unit. The call returns the coalesced `write_set` (the union of every member's `touches`/`files_to_modify`); serialize the next wave against that union, since harness executes the coalesce but never picks what to coalesce.

**Write-set serialization (Task 292):** `dispatch-bundle` and cron ready-set dispatch compute each task's `touches ∪ files_to_modify` before enqueue. Tasks with overlapping write-sets are logged and serialized into later waves instead of fanned out together. Callers no longer hand-dedupe ready sets; they must keep `touches` / `files_to_modify` accurate because harness does not infer paths from task prose.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. All six shipped adapters declare `worktree_isolation: true`.

### Routing & Model Management

- **Resolve `assignee` + `model` from facts, not by reading code.** `routing-brief` is the thin task-writer index: dispatchable agent roster, each agent's standing model (`Config.agent_model/1`), model availability/blocks, and per-agent KPI rollups — every metric carries `n`, no ranking. A model-capable agent with no configured model shows `model: nil, model_required: true`.
- **Scout routing (advisory).** `dispatch-recommend` returns the cross-family scout AI's per-facet `:exploit` pick (with rationale) or a safe `:explore` / `:fallback_no_data` when a facet is unmeasured; `dispatch-assess_facets` forces a fresh scout assessment. The caller decides whether to dispatch the pick — legacy composite scores are not used for routing.
- **Model is required, never defaulted.** Implementer precedence: **task `model` → `{:agent_model, agent}` → REJECT** (`{:model_required, agent}`) — harness never falls through to the CLI's ambient default. The **reviewer has no task-pin axis**: its model comes solely from `{:agent_model, agent}` for the reviewer adapter's agent (`Run.reviewer_model/1`), and a model-capable reviewer with no configured model is rejected *before* the reviewer spawns. Antigravity is model-capable as of `agy` 1.0.10 (`--model` + `agy models`); harness validates pins against its catalog because the CLI silently falls back on unknown ids.
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

Failed runs retain the worktree at `result.worktree_path` for inspection. Approved runs keep branch `harness/<run-id>` after worktree teardown. Use `dispatch-verdict_detail` for the reviewer report, ratings, checks, concerns, proposed tasks, warning flag, and `reviewer_diff_size` — no harness-run mechanical per-check stdout.

**The verdict artifact** `.harness/review.json` is `{verdict, run_id, review_attempt, report, checks, concerns, proposed_tasks, facets, skills, ratings}`: `verdict` (`approve`/`reject`) is the gate; `run_id` and `review_attempt` fence the file to the reviewer invocation that wrote it (echoed from `HARNESS_RUN_ID` / `HARNESS_REVIEW_ATTEMPT`; a mismatch is treated as missing); `report` is the reviewer's prose; `checks` is the reviewer-written record of commands run and their pass/fail claim; `concerns` is the reviewer's self-flagged caveat list; `proposed_tasks` is an optional list of structured discovery proposals (`title`, `body`, suggested scores/markers, and evidence); **`facets`** (open-vocabulary routing KEY — the kind of task) and **`skills`** (v0_13 two-axis rubric, routing VALUE) feed per-facet capability routing; `ratings` is the legacy flat-score fallback. Harness persists proposals verbatim but never files them. After a run lands, the orchestrator reads them from `dispatch-verdict_detail`, dedupes/merges them against the live pending set, and files only warranted tasks through its own task-writing gate. Reviewers never edit `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, or `CHANGELOG.md`; those files are excluded from delivery commits alongside `.harness/`. Approved runs with non-empty concerns or a reviewer-authored failed check surface a warning fact; harness never auto-blocks or classifies prose. The artifact lives under `.harness/` (excluded from staging) so it never rides in the deliverable commit. The file is removed before every reviewer spawn so a killed reviewer's stale approve cannot settle the run.

**External-system evidence is reviewer-owned judgment.** When acceptance criteria touch an API or external service, the reviewer must look for reality rather than plausibility: a live success call, a relevant live error, the provider's official docs/spec/SDK for semantic meaning, and an integration test pinning the observed domain semantics. Third-party clients, aggregators, wrappers, and reference implementations (including CCXT) are compatibility/reference evidence only; they never establish correctness or override the provider-owned contract. Mocks, fixtures, and the implementer's self-report are not independent evidence. Missing credentials or an unreachable sandbox are surfaced as a failed check/concern (or rejection when the criterion cannot be verified), never silently treated as green. The lander records the reviewer identity plus `harness-run:<run-id>` as rmap verification provenance.

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

**🚨 First, confirm the run actually *didn't* land — check `origin`, not your local checkout.** Under `landing_policy: :auto` the lander pushes to `origin/<target>` from a detached worktree, then `Harness.Git.TargetSync` may fast-forward the operator's local target when that is safe (off-target → ff the branch ref; on-target + clean tree → `merge --ff-only`). It skips — witnessed, never `--force` — when the tree is dirty, the update is not a fast-forward, or the target is this running node's own source tree (self-host: path identity, not the project name). Under dogfooding that self-host skip is the common case, so after an autonomous land your local `tasks.toml` is **stale**: it still reads `in_progress` for a task the lander already marked `done --shipped-in` on origin. **Reading that stale local status as "the run didn't land" is the trap** — it triggers a wasteful reset-to-`pending` + re-dispatch that *duplicate-lands already-shipped work*. Before concluding anything from task status, `git fetch origin <target> && git rebase origin/<target>` (the existing "Sync main before committing" rule) or read ground truth directly:
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
- **Repo-wide invariant tasks run EXCLUSIVE.** A task whose real write-set is "the whole surface" — introduce a repo-wide guard/invariant and convert every violating site (e.g. an AST-scan test over all of `test/`) — cannot be write-set-serialized by declared `touches`: any sibling land that adds a new violating site after the fork reddens the guard at landing time (observed ccxt_client task 433 × 435, 2026-07-19). Dispatch such tasks as a solo wave — nothing lands in parallel — or accept that the orchestrator repairs at landing.
- **Land-conflict repair is a standard orchestrator move, not an incident.** When the lander blocks on a rebase conflict (reason retains the branch): fork a repair worktree off `origin/<target>`, cherry-pick the run commits, resolve (for additive `tasks.toml` collisions: renumber the branch-side new task to the next free id on origin **and rewrite in-diff string references to it** — CHANGELOG lines, code comments; then `rmap validate && rmap render`), point the retained `harness/<run-id>` branch at the repaired tip, and `dispatch-reland` — the lander keeps push authority and advances rmap itself. **Do not re-run gates on a roadmap/doc-only repair:** the reviewer already graded the code; renumbering tasks, merging doc entries, and re-rendering the roadmap change nothing the gates measure, and a clean disjoint auto-merge of verified code needs no re-grade (same token-economy rule as everywhere else). Re-run a check ONLY when the repair touched code, or when the conflict overlapped a repo-wide invariant the sibling lands could have violated (e.g. a new suite-wide guard vs tests added after the fork — run just that guard, not the stack). Never reset-to-pending (that redoes paid work), never hand-push to the target when a reland can land it.

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch`:

1. Approved run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` rebases `harness/<run-id>` onto `origin/<target>` in a detached worktree
3. **ff-pushes without re-verification** — the reviewer already gated the work
4. Successful push enqueues post-merge audit; advances rmap (`done --verified --verified-by <reviewer> --verification-ref harness-run:<run-id> --shipped-in <sha>`)

Conflict / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

**🚨 Never block on `dispatch-await*` — monitor `origin` for the landing commit instead.**
This is the standing rule for waiting on a wave, not a fallback. `dispatch-await` /
`dispatch-await_runs` hold an MCP request open for the entire run, and an MCP client
kills a tool call that emits no progress for its idle timeout (Claude Code's default is
300s — far shorter than any real run). The call dies, the orchestrator learns nothing,
and the runs keep going regardless. Worse, awaiting the wrong signal: **await returns at
reviewer settle, which fires BEFORE the serialized `landing_<name>` job rebases and
ff-pushes** — so even a successful `approve` means "approved and *queued* to land," never
"on `origin/<target>`."

**The primitive that actually works — watch the target branch for the lander's own
commits.** The lander pushes `task <id> -> done (shipped <sha>)` to `origin/<target>`;
that commit IS the landed signal, it is durable, and it survives a dead MCP call, a
restarted session, and a node bounce. Arm one background watcher per wave and keep
working:

```bash
# one notification per landed task, exits when the whole wave is in
cd <source-checkout>
WAVE="615 623 569 619"; seen=""
while true; do
  git fetch -q origin <target> || true
  for t in $WAVE; do
    case " $seen " in *" $t "*) continue;; esac
    if git log --oneline origin/<target> | grep -q "task $t -> done"; then
      echo "LANDED task $t"; seen="$seen $t"
    fi
  done
  [ "$(echo $seen | wc -w)" -eq "$(echo $WAVE | wc -w)" ] && { echo "WAVE COMPLETE"; break; }
  sleep 60
done
```

Poll `dispatch-status <run-id>` only to diagnose a run that the watcher shows as *not*
landing — a `:failed` verdict, a rebase conflict that retained the branch, a hung
implementer. Status is for diagnosis; git is for waiting.

**Silence is not success** — a run that fails review or blocks on a land conflict never
produces a landing commit, so a watcher greping only for `-> done` stays quiet forever.
Bound every wave watch with a deadline, and when it expires without `WAVE COMPLETE`,
reconcile the missing tasks through `dispatch-status` / `result_store-list_run_records`
before assuming anything.

Same root cause as the duplicate-land trap above, seen from the dispatch side: **origin is
the source of truth for what landed** — not an await return value, not a local
`tasks.toml`, not a transcript.

**Herdr panes are an optional operator convenience for watching, never a harness
surface.** When the orchestrator session runs inside Herdr (`HERDR_ENV=1` — the
operator's default), the wave watcher above and ad-hoc run babysitting can run
*visibly*: `herdr pane split --current --no-focus` + `pane run` for the watcher
loop, an attach pane tailing `dispatch-transcript` for a run under scrutiny,
`herdr worktree open --path <retained-worktree>` to inspect a failed run, and
`herdr notification show "…" --sound done` as a configured witness-notification
sink. Strictly operator-side: dispatched agents stay headless over Ports, and
Herdr's `idle`/`blocked` classification is never a harness signal (adjudicated —
harness repo `docs/orchestration-library-evaluation.md`, Addendum 2026-08-25,
incl. the deliberately unmitigated `HERDR_*` env-inheritance risk for dispatched
agents).

**Cron manual-approval mode.** A per-project cron poller in `:auto` mode dispatches unattended; in `:manual` mode it **parks** each dispatch decision instead of enqueuing — drain the parked decisions with `dispatch-pending` and approve them with `dispatch-approve`, keeping the orchestrator in the loop for autonomous polling.

### Orchestrator Loop — the Architect Seat the Per-Task Reviewer Can't Fill

The sections above document the *mechanisms*; this is the **continuous loop** the driving AI runs across waves:

```
plan wave → dispatch → watch origin for the landing commits → run integration suite on the landed base
          ↑                                                     + review whole surface vs roadmap intent & domain invariants
          └── reconcile rmap ← encode any whole-surface finding as a criterion/test ←┘
```

Each arrow reuses an existing mechanism — don't restate them here: *watch origin for the landing commits* (§ "Never block on `dispatch-await*`", and § "Recover, Don't Redo" → the duplicate-land trap), *reconcile rmap* (the lander already advanced `done --shipped-in` under auto-land — verify, don't double-write), *next wave* (§ "Parallel Dispatch" + write-set serialization).

**🚨 Three review seats, each blind where the next sees — the orchestrator seat is mandatory, not optional.** The per-task reviewer gates *one diff against one task* and is **structurally blind** to two defect classes that land clean through it (worked evidence: delta_calc tasks 24/25/26, see its `## Review Blind Spots` / `## Domain Invariants`):

| Seat | What it sees | What it CANNOT see |
|---|---|---|
| **Per-task reviewer** (cross-family, the gate) | one diff vs one task's acceptance criteria + mechanical checks, in an isolated worktree off a base | the whole surface; domain ground truth |
| **Post-merge audit AI** (best-effort) | cold build of the merged commit range; hygiene | whether a domain constant is *wrong*; roadmap-intent fit |
| **Orchestrator** (the architect seat — you) | whole integrated surface vs roadmap intent + domain invariants across all landed waves | — (this is the seat of last resort) |

The two blind classes, both real-correctness, both passing every per-task check:

- **Domain ground truth** — a wrong venue constant (`@funding_periods_per_day 3`, overstating Deribit's hourly funding ~8×) is internally consistent and fully tested *because the golden was computed with the same wrong constant* — coverage ratifies the bug. The reviewer has no signal; that knowledge lives in the architect's head.
- **Cross-module global invariants** — write-set-disjoint parallel dispatch means two worktrees can each define `project_payback_timeline` and neither review sees the other; the collision only exists once both have landed on the integrated base. Only a whole-surface seat catches it.

**🚨 Run the integration suite on the landed base — this is NOT redundant with per-task review.** After each wave lands, run the project's full check (`mix ci` / `mix precommit.full`) on the freshly-landed `origin/<target>`. The per-task reviewer ran the dispatch-scale check hint (for Elixir, `mix check.dispatch` plus focused `mix test.json ...` for touched behavior) in an *isolated worktree off an earlier base, before sibling waves landed* — cross-module breakage doesn't exist until multiple landed diffs coexist. This generalizes the manual-landing-only "run the project's check command on target after last merge" (§ "Parallel Dispatch") into a standing per-wave step.

**Capture dispatch-check output once, to a unique tmp log.** Dispatch checks are normally verbose. The reviewer should capture the first run instead of re-running for readability: `LOG=$(mktemp -t harness-check-dispatch.XXXXXX.log)` then `mix check.dispatch > "$LOG" 2>&1`; inspect with `tail -200 "$LOG"` / `rg "error|failed|warning" "$LOG"` and record the log path in `.harness/review.json`. The random `mktemp` path prevents parallel agents from clobbering each other's logs.

**🚨 Architect/QA is a workflow responsibility, not a harness runtime gate.** After a wave lands, the orchestrator must run the full landed-base gate, review the integrated surface against roadmap intent/domain invariants, fix findings, and only then dispatch the next wave. Harness does not pause dispatches or store a completion marker for this step; this is the driving AI's seat.

**Two framing guards — keep this consistent with the harness mantra:**

- **It's an agent seat, not harness code.** The mantra ("count facts in code; judge with an AI") forbids *harness* computing meaning — it does **not** forbid the orchestrator AI from reviewing the whole surface or running the suite. This adds no mechanical gate to harness; it's judgment in an agent, which is exactly where judgment belongs.
- **The output crystallizes into encoded invariants — don't leave it a manual sweep.** When the architect seat catches a whole-surface or domain defect, the highest-value move is not the manual catch — it's pushing the rule into an **acceptance criterion or a manifest-wide CI test** (the delta_calc rule) so the per-task gate absorbs that class going forward. Orchestrator review *feeds* the criteria/CI; it must not become a permanent re-review of every diff. A finding caught twice by hand is a missing test.

**Convergence sweep (append-only).** The architect seat's whole-surface pass has a disciplined output shape (inspired by spec-kit's `/speckit.converge`, github/spec-kit): assess the landed code against the **roadmap + acceptance criteria as the sole source of intent** — never against the orchestrator's memory of what it dispatched or what a transcript claimed. Three rules:

- **Sole source of intent.** The gap being measured is code vs. `tasks.toml` ACs and roadmap/milestone intent. If the intent itself was wrong, that's a task edit first, then a sweep against the corrected intent.
- **Append, never rewrite.** Every unmet criterion, partial delivery, or intent gap becomes a **new `rmap new` task** (D/B/U-scored, gated per `task-writing.md`) referencing the task it converges on. Never reopen, rewrite, renumber, or edit the history of existing tasks to make the gap disappear — `attempts`/`implemented` records are evidence, not scratch space.
- **Clean sweep = zero mutations.** When the surface already satisfies the roadmap, the sweep leaves `tasks.toml` **byte-for-byte unchanged** — no empty "convergence" ceremony entries, no touched timestamps. A sweep that always writes something is measuring itself, not the code.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Reviewer discoveries arrive as proposals, and the ORCHESTRATOR files them post-land.** A reviewer that filed a discovery by editing `roadmap/tasks.toml` in its worktree assigned ids from a stale fork (id collisions that block the lander — observed ccxt_client 2026-07-19), couldn't see the live pending set (so the one-session=one-task merge gate never fired), and made roadmap files a universal write-set overlap across "disjoint" waves. That channel is closed: reviewers now emit `proposed_tasks` in `.harness/review.json`, and `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, and `CHANGELOG.md` are excluded from delivery commits, so a run diff carries only code. After each land, read the proposals via `dispatch-verdict_detail` and file only the warranted ones through your own task-writing gate — dedupe against the live pending set, merge per `task-writing.md`, score with real ids off `origin`. Harness persists proposals verbatim and never files them.
  - **🚨 Default-DECLINE — the proposal pipeline outproduces the backlog's right to grow.** Reviewer + audit agents emit ~1 proposal per run; an orchestrator that files "everything evidenced and cross-session" lands N tasks and files N new ones per wave — net backlog delta ±0, the roadmap never converges (observed ccxt_client 2026-07-22: 11 landed, 11 filed in one session, including a D2 one-file fix filed+dispatched instead of done inline, a B4/U3 cosmetic filed instead of declined, and a follow-up that existed only because its parent was scoped as a patch instead of the invariant). Evidence + cross-session is the FLOOR, not the bar. File a proposal only when ALL THREE hold: (a) real defect or invariant gap with evidence, (b) not foldable into an existing pending task — and when the proposal patches an instance of a class, scope the filing as the CLASS invariant so the next instance can't spawn a sibling task, (c) not inline-doable in minutes by the orchestrator — if it is, DO it now instead of filing. Declined proposals need no ceremony: the verdict record in the ResultStore is their evidence trail.
  - **Report the net backlog delta** (landed − filed) as an explicit number in every wave/session wrap-up. A session trending ±0 or negative-growth is the churn alarm firing — tighten the decline bar, don't normalize it.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **`check_command` is a dispatch-scale hint to the reviewer.** Free text (e.g. `"mix check.dispatch"` for Elixir, with focused tests chosen by the reviewer) — the reviewer runs and judges it; harness does not execute it mechanically. Keep full-suite commands like `mix precommit.full` for the landed-base Architect/QA pass. For verbose checks, capture to a per-run `mktemp` log on the first execution; never re-run only to recover truncated output.
- **The cross-family reviewer reads `AGENTS.md`, not your Claude skills/includes.** `AGENTS.md` is generated from `CLAUDE.md` by `claude-marketplace/scripts/sync-agents-md.sh`, which recursively inlines every `@`-import. **Regenerate it after any `CLAUDE.md` change** (`bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh`, or `--dry-run` to preview) so the reviewer gates against current rules — a stale `AGENTS.md` makes codex/cursor/grok judge against rules you've already changed. **`--check` is the freshness gate** — it re-renders in memory and exits non-zero if `AGENTS.md` has drifted (diffs rendered output, not mtimes, so it catches drift in transitive `@`-imports too); wire it into CI / a pre-commit hook / the `check_command` so staleness fails loudly instead of silently. Consequence under Opus-4.8 skill-on-demand: once `CLAUDE.md` slims to the eager floor, reviewer-critical facts that *were* carried by eager includes (the `check_command` gate; that `mix test.json` / `mix dialyzer.json` emit JSON **by design** — parse for real failures, never flag the envelope; plain `mix dialyzer` is authoritative when the JSON encoder can't serialize a warning) no longer reach `AGENTS.md` via those imports. Put them in a **self-contained `## Toolchain & check commands` section in `CLAUDE.md`** so they survive the slim-down and flow into `AGENTS.md` on regen (ref: `tapakly/CLAUDE.md`, `ccxt_extract/CLAUDE.md`).
- **Delegation roster — opus last, and don't over-default to codex.** When assigning a dispatchable task to a harness adapter, prefer the external agents — **cursor, codex, grok** — and reserve the **claude/opus** adapter for work that genuinely needs it (harness-surface changes, judgment-heavy review, tasks the cheaper adapters keep bouncing). Opus tokens are precious: spend them last, not by default. Mix adapters across a wave for review coverage — but `cursor`+`grok` is one family, not two (see cursor bullet). A repo may override the roster in its own CLAUDE.md.
  - **Observed failure mode: reflex-routing everything to `codex`.** Run ledgers skew heavily codex-over-cursor/grok. Actively spread `assignee` across all three; reserve codex for tasks it's genuinely scored best on, not as the default.
  - **`cursor` is back on the roster (operator unblocked 2026-08-15).** SuperGrok Heavy entitles Cursor Ultra; the 2026-07-13 `cursor/all` block is lifted. Pin `model = "cursor-grok-4.6-high"` — **operator decision 2026-08-17: no more Composer pins.** The older `composer-2.5` guidance (cheapest cost-to-green, and where every cursor capability KPI was measured) is retired; that ledger data describes a model the operator no longer wants routed to. Confirm the live id with `cursor-agent --list-models` / `model_availability-list_available_models cursor` (the catalog also carries `cursor-grok-4.6-xhigh` / `-fast` variants and `claude-opus-5-*` — Opus/frontier pins through cursor still exhaust and get operator-blocked, so don't reach for them as the "design-heavy" reflex). **`cursor` and `grok` are the same SpaceXAI family** (SpaceX closed the Cursor acquisition 2026-08-14): three adapters, two families. A cursor implementer must not get a grok reviewer (and vice versa) — pair either with `codex`.
  - **`model` is REQUIRED at creation for any non-`human` assignee** (`rmap new` rejects a model-less dispatchable task — "a dispatchable task must pin the LLM it runs on"; see `rmap.md` § "Pinning an LLM model"); "leave `model` unset for the agent default" does NOT work. Set `assignee` **and** `model` at task creation per `rmap.md`.
  - **`grok` runs on `grok-4.6` — the frontier default since 2026-08-13; `grok-4.5` is gone from the live catalog** (lineage: `grok-build` → `grok-4.5` 2026-07 → `grok-4.6`; a catalog refresh on 2026-08-13 listed only `grok-4.6`). Re-pin any task still carrying `grok-4.5` when you touch it — a retired pin fails at dispatch. `grok-4.6` carries **no** capability/cost-to-green data yet — route to it to *gather* that data (A/B via `dispatch-compare` grok-4.6 vs codex/gpt-5.6-sol), not on a performance claim the ledger doesn't yet show. A newly-probed grok model lands in the catalog as `selected?: false`; select it (`model_availability` toggle) before it's dispatchable. Confirm live ids with `grok models` / `model_availability-list_available_models grok`.
  - **`codex` runs on `gpt-5.6-sol` — the standing default since 2026-07-31; `gpt-5.5` is RETIRED from the live catalog.** The GPT-5.6 family (2026-07-10) splits generation from durable capability tier: **Sol** = flagship (complex reasoning/coding/agentic, $5/$30 per 1M tok), **Terra** = balanced (~5.5-competitive at 2× cheaper, $2.50/$15), **Luna** = fast/cheap ($1/$6). Model ids: `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` — the live catalog lists ONLY these three; `agent_model.codex` is pinned to `gpt-5.6-sol` (verified 2026-07-31 via `config-get agent_model.codex` + `model_availability-list_available_models codex`). **Pin `model = "gpt-5.6-sol"` for new codex tasks**, and re-pin any task still carrying `gpt-5.5` when you touch it — a retired pin fails at dispatch. `terra` remains the cost-to-green candidate (2× cheaper, ~5.5-competitive) — A/B it via `dispatch-compare` before routing bulk work to it. Confirm live ids with `codex debug models` / `model_availability-list_available_models codex`; a probe failure falls back to the builtin seed.
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
