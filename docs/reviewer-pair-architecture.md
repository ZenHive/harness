# Reviewer-Pair Run Lifecycle — Settled Architecture Decision

**Date settled:** 2026-06-02
**Status:** direction approved; implementation tracked in roadmap phase "Reviewer-Pair Lifecycle"
**Supersedes:** FailureClass, RetryPolicy quota classification, RepairPrompt, the in-run repair loop, BaselineFilter, baseline verification (`:base_red`), the semantic gate as a separate mechanism, `:no_changes` disposition logic

## The principle

**Judgment lives in agents. Harness code is mechanical substrate only.**

A run lifecycle is full of questions that look like engineering but are actually
reading-comprehension:

- *Why* did this run fail — quota, infrastructure, or real red?
- Is this credo finding the agent's fault or pre-existing debt?
- Does an empty diff mean "task already implemented" or "agent did nothing"?
- Is this red verdict worth repairing, retrying, or abandoning?
- Does this green code actually satisfy the acceptance criteria?

Harness has been answering these with procedural code: regexes, cond branches,
baseline diffing, disposition tables. Every one of them became a bug factory,
because the input space — agent behavior, transcripts, repo states — is semantic
and unenumerable. The score as of 2026-06-02:

| Bug / task | Judgment call encoded as code | Failure mode |
|---|---|---|
| Task 153/160 | "whose fault is this finding?" → BaselineFilter + baseline re-run | inherited debt masked agent faults as `:base_red`; repair loop robbed |
| Task 156/157 | "is this run still alive?" → restart/rescue plumbing | runs silently lost / zombied on BEAM restart |
| Task 158 | "should green enter the semantic gate?" → enable/availability conds | gate rejected green runs when no grader existed |
| Task 159 | "what does an empty diff mean?" → `:no_changes` disposition | already-implemented tasks wedged `in_progress`, never graded |
| (unfiled, found 2026-06-02) | "why did this run fail?" → `~r/quota/i` on output | failing tests *named* "quota-exhausted" classified as agent quota → repair suppressed → bogus Oban snooze-retry → branch collision loop |
| (codex's 159 delivery) | "which empty diffs deserve verification?" → more cond branches | quota-exhausted no-op runs would settle `:done` |

Zero of these bugs are in the check stack itself. `mix test` and `credo` were right
every time. **All of them are judgment calls implemented as procedural code.** This
is not a list of edge cases to fix; it is one architectural mistake expressing
itself repeatedly. More cond branches produce more of the same.

This also violates harness's own founding design ("no agent-output parsing — the
consumer is an AI that reads each agent's raw JSON natively"). The quota regex IS
agent-output parsing. The judgment layer was always supposed to be an AI; it crept
into the substrate as code.

## The decision

The run lifecycle becomes an **implementer → reviewer pair**:

```
dispatch (mechanical)
  → implementer agent works in worktree (mechanical capture)
  → harness commits the delivery (mechanical)
  → check stack runs (mechanical, deterministic)
  → GREEN and no review required        → done
  → RED / empty diff / green-needs-review →
      REVIEWER agent (cross-family) gets: task spec + acceptance criteria,
      implementer transcript, diff, check output, the worktree itself.
      The reviewer FIXES INLINE — its own edits, its own commits, re-runs
      checks — until the stack is green, or it concludes "genuinely stuck
      because <prose reason>".
  → harness re-runs the check stack (mechanical — the reviewer's word is
      never trusted; the worktree must BE green)
  → green → done    |    stuck-report → failed (prose reason in run_records)
```

Bounded by one mechanical cap: `max_review_iterations` (default 2). That is the
only knob.

### Why "reviewer fixes inline" beats "classifier returns decisions"

An intermediate design was considered: keep the state machine, replace the regexes
with an LLM *classifier* that returns structured decisions (`:quota`, `:repairable`,
`:pre_existing`). Rejected — a classifier still needs procedural code to **act** on
its classifications, and that acting code is exactly the bug factory being removed.
The reviewer doesn't return decisions for harness to interpret; it does the work.
The only contract is mechanical: *the worktree ends green, or you write prose.*

### What each old mechanism becomes

| Old mechanism | In the new model |
|---|---|
| Repair loop (resume implementer with failing checks) | Reviewer fixes directly — no resume protocol, no repair prompts |
| FailureClass (quota/transient/terminal regex) | Reviewer reads the transcript; its stuck-report says what happened |
| BaselineFilter + baseline re-run + `:base_red` | Reviewer fixes whatever is red — pre-existing debt gets *paid*, not filtered around |
| Semantic gate (separate post-green consultation) | "Review green code against acceptance criteria" is just a reviewer invocation (`review_green: true` per project) |
| `:no_changes` disposition | Reviewer looks at an empty diff and decides: already-implemented (verify → green → done) vs nothing-happened (stuck-report) |
| Cross-agent repair / AuditReview-as-grader | The reviewer IS the cross-family agent; AuditReview's prompt-building seeds the reviewer prompt |
| Quota failover signal (regex → AgentRegistry) | Reviewer's stuck-report includes what it observed ("implementer hit usage limit at …"); batch failover / the orchestrator reads that |

## Evaluator separation — preserved, strengthened

- The **check stack stays deterministic** and stays the ground truth. A reviewer
  cannot talk its way to `done`; harness re-runs the stack after review and only a
  green worktree settles `done`. (`verified` in rmap stays honest.)
- **Implementer ≠ reviewer**, enforced by family: the reviewer adapter must be a
  different agent family than the implementer (the existing claude ↔ codex
  auto-pairing generalizes; explicit `reviewer:` override per project/dispatch).
- The reviewer is judged by the same standard: its edits go through the same
  check stack it is trying to satisfy.

## What gets deleted (the reasoning)

The test for deletion is the principle itself: *does this code make a judgment
call?* If yes, it goes — the reviewer absorbs the judgment. If it is genuinely
mechanical (timers, git, ports, persistence), it stays.

| Delete | ~Lines | Reasoning |
|---|---|---|
| `Harness.Run.FailureClass` | 131 | Pure judgment ("why did this fail?") by regex. Already produced a false positive that cascaded into 4 failures. The reviewer reads the transcript. |
| `RetryPolicy.quota_patterns` + quota classification + failover-on-quota | ~60 | Same judgment, same regexes. Mechanical retry (crash, port death) keeps a *simple backoff* — no text matching. |
| `Harness.Run.RepairPrompt` | 100 | Repair prompts exist to teach the *implementer* about failures across a resume boundary. The reviewer sees the check output and the code directly; there is nothing to format. |
| Repair loop in `Run` gen_statem (`repair_attempts`, `max_repair_attempts`, `repair_prompt_kind`, `last_failed_check_signatures`, verifying→running loopback) | ~120 | The repair loop is "judgment about whether/how to retry the implementer." Replaced by the reviewing state. |
| Consulting state + `cross_agent_repair` machinery (`cross_agent_repairable?`, `cross_agent_consulted`, repeated-failure detection) | ~100 | This was a half-step toward the reviewer (consult another agent, but only to *grade*, not to fix). The full step makes it redundant. |
| Semantic gate as separate mechanism (`settle_green_verdict`, `semantic_gate_enabled?`, `semantic_gate_grader_available?`, `consultation_kind: :semantic_gate`) — including Task 158's fix | ~80 | The gate is a reviewer invocation with scope "green code vs acceptance criteria." A project flag (`review_green`) replaces the mode enum. |
| Baseline verification in `Harness.Verification` (`run_baseline_stacks`, `mark_pre_existing`, `:persistent_term` baseline cache, `:base_red`) — Tasks 153 + 160 | ~150 | Existed to answer "whose fault is this red?" so the repair loop wouldn't punish agents for inherited debt. The reviewer doesn't need attribution — it fixes the red, whoever caused it. Debt gets paid down instead of filtered. |
| `Harness.Verification.BaselineFilter.Credo` | 273 | Same. |
| `:no_changes` disposition + Task 159's `verify_no_changes?` refinement | ~40 | Empty-diff meaning is judgment. Reviewer decides. |
| `Run.Worker` snooze-on-quota / snooze-on-judgment | ~30 | Oban retry becomes crash-only (BEAM death, port crash, worktree-creation race). A settled run — any verdict — is never re-run by the queue. |

**Total: ~1,100 lines of judgment code deleted**, replaced by one new gen_statem
state (`:reviewing`), reviewer prompt assembly, and a re-verify step — all
mechanical.

**Actuals (deletion pass landed 2026-06-02, Task 163):** `lib/` + `config/`
net **−1,219 lines** (+470/−1,689 across 32 files); the whole pass including
the test rewrites nets **−1,702** (+959/−2,661 across 66 files). The big
movers: `run.ex` −545/+93 (repair loop, consulting state, semantic gate,
quota regexes), `verification.ex` −173/+28 (baseline machinery + post_process
plumbing), `retry_policy.ex` −136/+18 (rewritten to backoff arithmetic only),
plus the three whole-module deletions (FailureClass 131, RepairPrompt 100,
BaselineFilter.Credo 273).

### What stays (and why it's allowed to)

| Stays | Why it passes the test |
|---|---|
| `Harness.Run.Reflex` | Its own moduledoc: "deliberately mechanical: timers, filesystem fingerprints, pattern matches only." Watchdogs are not judgment. This module is the model of the boundary done right. |
| `Harness.Verification` check execution | Runs commands, reads exit codes. The ground truth. |
| Worktree / Git / Port / Oban / run_records | Physical operations and persistence. |
| `Run` gen_statem skeleton | States and transitions are mechanical; what was wrong was the judgment *inside* the transitions. |
| `AgentRegistry` | A mechanical availability hint (now fed by reviewer reports instead of regex classification). |
| `max_review_iterations` cap | A counter. Counters are allowed. |

## Dispatch-level retry (the Oban boundary)

With judgment removed from the worker, the Oban contract simplifies to:

- **Retry**: only mechanical failures — BEAM restart mid-run, port spawn failure,
  worktree-creation race. Retrying requires first cleaning up the prior attempt's
  worktree/branch (the 2026-06-02 branch-collision bug: stable run ids + leftover
  branches make naive retry impossible by construction).
- **Never retry**: any run that reached a settled verdict (green, stuck-report,
  reviewer exhausted). Settled is settled; re-running it is the queue making a
  judgment call.

## Migration sequencing

The old machinery keeps working until the new path replaces it — each step is a
dispatchable task, graded by the existing stack:

1. **Reviewer core**: `:reviewing` state, cross-family reviewer selection, reviewer
   prompt assembly, post-review re-verify, iteration cap. Red verdicts route to
   the reviewer instead of the repair loop.
2. **Empty-diff + green-review routing**: route `:no_changes` and (when
   `review_green`) green verdicts through the same reviewing state. Semantic gate
   mode collapses into `review_green`.
3. **The deletion pass**: remove FailureClass, RepairPrompt, BaselineFilter,
   baseline verification, quota patterns, repair fields, consulting state,
   semantic-gate machinery. Run.Worker goes crash-only-retry with worktree cleanup.
4. **Docs/driver surface**: harness-driver SKILL.md, CLAUDE.md, dashboard
   StatusView fields (repair_attempts → review_iterations), run_records columns.

Interim (already filed as independent bugs, needed before step 3 lands):
worktree/branch cleanup before Oban retry; run_records upsert must not overwrite
a prior attempt's settled data. **Both landed inside step 3** —
`Worktree.cleanup_for_run/2` runs before every mechanical Oban retry, and the
Postgres `record_run` upsert COALESCEs rich evidence columns so a sparse later
write never clobbers a settled attempt.
