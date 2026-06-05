# The Agent-Gate Workflow — Settled Architecture

**Date settled:** 2026-06-03
**Status:** THE architecture. Landed as the agent-gate rebuild (hand-built, 2026-06-03).
**Supersedes:** `docs/reviewer-pair-architecture.md` (2026-06-02) and, transitively, everything
*it* superseded — the mechanical verification stack (`Harness.Verification`, `Harness.CheckStack`,
presets), verdicts, the `:verifying` state, `review_green`, `max_review_iterations`, lander
re-verification, and the mechanical benchmark corpus.

## The workflow

```
worktree → implementer AI → reviewer AI (THE GATE) → MERGE → audit AI

dispatched → running (implementer) → committing → reviewing (reviewer) → done | failed
                                                                            ↓ (done + auto policy)
                                                              MERGE (lander: rebase + ff-push)
                                                                            ↓
                                                              AUDIT (post-merge audit agent)
```

There is **no mechanical test runner / verification gate** in harness. The reviewer AI runs the
project's checks itself. Having harness also run them mechanically added wall-clock, crash
surface, false verdicts, and config burden for zero added judgment.

This is the autonomous version of the human worktree workflow
(`~/.claude/includes/worktree-workflow.md`) with every human/GitHub stage replaced by an AI:
implement (Claude session → implementer AI), gate (GitHub CI/reviewer → reviewer AI), merge
(`gh pr merge` → lander ff-push), audit (`staged-review:audit-review` skill → audit AI worker).
No GitHub PRs anywhere — merge is a local rebase + ff-push.

## The principle

**Everything that interprets meaning is an agent's job, never harness code.** Is the work good?
Why did a run fail? What does an empty diff mean? Does the code satisfy the acceptance criteria?
Do the tests pass *in a way that matters*? — all judgment, all agent work.

Harness code is mechanical substrate only: worktrees, git, Ports, Oban persistence, counters,
timers/watchdogs, reading the reviewer's verdict file.

**The evidence that settled it:** every run-lifecycle bug from 2026-05-26 → 06-03 (tasks 153–163,
168, 169, 171, 172, the task-41 verifier crash, the task-172 failure) traced to the *harness
verification/lifecycle machinery* — false reds, false greens, verifier crashes, timeout
misconfig, preset gaps. Zero traced to an agent's judgment. 32 salvage/repair/fix commits in 257.

## The stages

### Implementer AI

Works in the isolated worktree (`harness/<run-id>` branch), commits — or leaves edits for
harness's mechanical `committing` step to commit. Its self-report is never trusted.

### Reviewer AI — cross-family, mandatory, THE gate

Gets: worktree + task + acceptance criteria + implementer transcript tail + diff stat + the
project's `check_command` hint (free text, e.g. `"mix precommit"`).

It reviews, **runs the checks itself**, fixes inline (its own edits, its own commits), then
writes `.harness/review.json`:

```json
{
  "verdict": "approve" | "reject",
  "report": "prose — what it found, what it fixed, why the verdict",
  "ratings": { "performance": 1-10, "truthfulness": 1-10, "code_quality": 1-10, "idiom_usage": 1-10 }
}
```

Harness reads the file mechanically (`Harness.Run.Review`):

- `approve` → run settles `:done`, reason `:approved` → landing enqueued (if `landing_policy: :auto`)
- `reject` → run settles `:failed`, reason `{:review_rejected, report}` → task back to the queue
- malformed → `:failed`, reason `{:review_stuck, report}`
- missing → the reviewer is re-prompted **once** in the same worktree to write its verdict (Task 203);
  a second miss settles `:failed`, reason `{:review_stuck, report}`. The re-prompt is mechanical — a
  re-issued flush of the artifact the reviewer owed, interpreting no work — so it stays inside the
  agent-gate rule rather than reopening "machinery interprets outcomes".

The `.harness/` directory is excluded from commits and diff measurement — the artifact is a
side channel, never part of the deliverable.

**Fix-and-approve is the near-absolute default.** A rejection costs two more full agent runs
(re-dispatch → re-implement → re-review) — roughly 2× the tokens of the reviewer just fixing the
problem. The reviewer prompt biases hard toward fixing: wrong approach, bugs, missing tests,
style — fix it all and approve. Rejection is reserved for degenerate cases only: an
empty/unusable worktree, destructive or fully off-task work, worktree corruption.

**The ratings block** scores the implementer (performance, truthfulness — self-report vs what
the reviewer actually found, code quality, idiom usage) and feeds `Harness.AgentKPI` /
`Harness.CapabilityScore`. Since rejection is near-never, approve/reject rate is *not* the
implementer quality signal — the ratings and the reviewer's fix-diff size
(`reviewer_diff_size`) are.

**Reviewer selection:** first dispatchable adapter from a different agent family than the
implementer (alphabetical), or an explicit `reviewer:` override per dispatch.

### MERGE — the lander

`Harness.Lander`, on the project's serialized `landing_<name>` Oban queue (limit 1):
fetch → detached worktree → rebase `harness/<run-id>` onto `origin/<target>` → **ff-push**
(never `--force`). No re-verification — the reviewer already gated the work. The operator's
checkout is untouched. A successful push enqueues the audit job (base_sha = the pre-land
`origin/<target>` tip).

Outcomes: `{:landed, sha}` · `{:conflict, out}` · `{:push_rejected, out}` · `{:reflex_halt, r}`
· `{:skipped, r}` · `{:error, r}`.

### Audit AI — post-merge, batched, best-effort

`Harness.Audit` (mechanics) + `Harness.Audit.Worker` (Oban shell, global `:audit` queue,
unique per project while available/scheduled). A third-family agent (∉ {implementer, reviewer})
gets a fresh detached worktree of `origin/<target>` and audits the **unaudited commit range**
(last `audit(...)` commit on the branch, falling back to the land's base_sha → HEAD).

It reuses `staged-review:audit-review`'s proven conventions: `.audit/<short-sha>.md` report
files committed in the repo, a single `audit(<short-sha>): ...` commit per pass, fix-forward
hygiene fixes committed inline. Harness ff-pushes only if HEAD advanced.

Outcomes: `{:audited, sha}` · `:noop` (range empty / already audited) · `:no_changes` (auditor
committed nothing) · `{:push_rejected, out}` · `{:skipped, r}` · `{:error, r}`.

### Roadmap state transitions — durable git, not local-file writes

Every rmap status transition the lifecycle makes on a project's *canonical*
`roadmap/tasks.toml` — `in_progress` at dispatch start (`Harness.Run.Worker`),
`pending` on terminal run failure, `done --verified --shipped-in` at land
(`Harness.Lander`), `blocked` on land-cap exhaustion (`Harness.Lander.Resilience`)
— is a **durable git operation**, not an uncommitted local-file write. All four
funnel through `Harness.Roadmap.mark_*`, which (when the project carries a
`target_branch` + local source) delegates to `Harness.Roadmap.Durable`: fetch the
target → mutate a fresh detached worktree at its tip → commit
(`roadmap: task <id> -> <status>`) → ff-push (non-ff push re-fetches, replays,
retries — never `--force`) → **fast-forward the operator's local `<target>`** to
the pushed commit (`Harness.Git.TargetSync`, ff-only, never touching a
dirty/diverged checkout).

That last step matters: pushing to origin but leaving the operator's working copy
stale is exactly how `roadmap/tasks.toml` drifts behind origin and a later merge
conflicts or silently loses the harness transition — so the local sync is part of
the durable write, not an afterthought. The same `TargetSync` core does the
lander's post-code-push local sync. Together they let concurrent sessions, cloud
agents, and other harness runs neither clobber *nor* fall behind each other's
roadmap edits (rmap's validate-then-write guards *invalid* writes, not *lost*
ones). A project without a `target_branch` (or a `{:github, _}` source) falls
back to the historical local rmap write. Mechanical substrate only — no judgment
branch added to harness code.

**Never blocks, never reverts.** A failed audit is logged and dropped; the merge stands.

## What is code vs what is judgment

The test for every line of harness code: **is it mechanical?**

| Stays code (mechanical) | Is agent judgment (never code) |
|---|---|
| Worktree create/commit/diff/teardown | Is the work good? Does it meet the AC? |
| Git operations, ff-push, rebase | Why did the run fail? |
| Port spawn, raw output capture | What does an empty diff mean? |
| Oban queues, persistence, retry backoff | Do the checks pass in a way that matters? |
| Counters, timers, watchdogs (`Harness.Run.Reflex`) | Is a check failure the agent's fault or pre-existing debt? |
| Reading `.harness/review.json` / `.harness/audit.json` | Whether to fix or reject |

**Rules for every session:**

- A run-lifecycle bug is fixed by **moving judgment into an agent prompt or verdict artifact** —
  never by adding a branch/regex/filter/classifier to harness code.
- Do not reintroduce: `Harness.Verification`, `Harness.CheckStack`, presets, verdicts,
  `:verifying`, baseline anything, repair loops, semantic gates, quota regexes, `review_green`,
  `max_review_iterations`, lander re-verification, the mechanical benchmark corpus.

## Run outcome vocabulary

| `state` / `reason` | Meaning |
|---|---|
| `:done` / `:approved` | Reviewer approved (possibly after fixing inline). Deliverable on `harness/<run-id>`. |
| `:failed` / `{:review_rejected, report}` | Reviewer found nothing salvageable. Task back to queue; `report` says why. |
| `:failed` / `{:review_stuck, report}` | Reviewer never wrote a readable `.harness/review.json`. |
| `:failed` / `{:worktree_failed, _}` `{:agent_spawn_failed, _}` `{:driver_crashed, _}` `{:commit_failed, _}` | Mechanical harness-side failure. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside its worktree (isolation trap fired by design). |
| `:failed` / `:timed_out` | Lifetime budget elapsed. |

## KPI semantics

- run_records `verdict` column stores `"approve"` / `"reject"` (the reviewer's decision).
- **success** = run `:done` (reviewer approved).
- **first_attempt_pass** = approved AND `reviewer_diff_size == 0` (implementer's work needed
  zero reviewer fixes).
- The reviewer's **ratings** block + **reviewer_diff_size** are the implementer quality signal.
- Reviewers get rated too: per-agent rejection rate is tracked; a high false-rejection rate
  deprioritizes that agent as reviewer (capability routing).

## Rejection writeback (pending rmap support)

The reviewer's rejection report should be written back to the rmap task so the next dispatch —
possibly a different implementer — sees why the last attempt was rejected. rmap has no surface
for this today (filed in `../rmap/`'s roadmap). Interim: the report is persisted in run_records
and can be injected into the next dispatch prompt for the same task id.
