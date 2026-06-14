# Audit report: c4ad9b5.. (range to c4ad9b5)

**Audited range (already merged):**  
c4ad9b5 (roadmap task 283 done marker)  
7540499 (task 283 agent delivery: ProjectRegistry.upsert/1 + live Oban queue scaling)  
550cd14 (CLAUDE.md toolchain note)  
8d34344 (chore: pin .tool-versions to Elixir 1.20.0-otp-29 / OTP 29.0.1)  
6cfafce + dd50e30 (roadmap markers for task 283 + phase 20 config-surface)  
2ecd887 (audit: thread auditor model into invocation)  
d1d62a6 (dashboard: reconcile failed-but-landed out of unmerged filter)  
... (full list per prompt: 281 dispatch-reland, 282 worktree bare staging + .harness gitignore, 280 lander task-id writeback/collision guard, 279 lander resolver regression, 278 poller double-dispatch guard, 277 dispatch-compare per-adapter model, 276 landed_sha persistence harden + reconcile, 275 lander prune branch+worktree, 274 routing-brief default collapse, 273 routing-brief thin index, 272 legacy CapabilityScore prune + dead-accessor sweep, 271/270/269/268 async:true test splits + dwell removal (267), 266 routing-brief, 265 model-catalog unification, 264 landed-state as persisted fact, model-availability probes, dispatch model-required guard, and supporting roadmap markers + review/test fixes back to ~9352613).

**Base marker for this pass:** ee52d91 (prior `audit(08aad3e)`).

**Scope of review (per prompt):** hygiene only — dead code, missing/stale docs, CHANGELOG gaps, leftover debug output, broken conventions, inconsistent naming. No re-verification of correctness, no reverts, fix-forward only. Judgment of landed work belongs to the cross-family reviewer that approved the originating runs.

## What was reviewed
- Git log + diffstat of the full range (ee52d91..c4ad9b5); focused file inspection on high-signal changes: `lib/harness/project_registry.ex` (new upsert + queue sync/scale/ensure), `lib/harness/audit.ex` (model threading), `lib/harness/lander*.ex`, `lib/harness/worktree.ex`, `lib/harness/run.ex` (landed_sha + fingerprint), `lib/harness/routing.ex`, `lib/harness/model_availability.ex`, `lib/harness/dispatch.ex`, result_store schema/migrations, test splits, .gitignore, CLAUDE.md, CHANGELOG.md, skills/harness-driver/SKILL.md, docs/orchestrator-surface-inventory.md, config/ and priv/playbooks references.
- Grep sweeps: bare TODO (none in lib/), stray IO.inspect/puts in lib/harness (only intentional Logger.debug + CLI mix tasks), dev.local.exs references (still accurate — phase-20 kill is 284/285), CapabilityScore.Legacy (only historical notes + tests asserting *absence* of legacy tools post-272), task_fingerprint (live in lander/run/roadmap/result_store for 280 collision guard).
- Prior .audit/ reports for tone; recent reviewer rejection note supplied in prompt (task 208 coverage — pre-dates this range).

## Findings
1. **CHANGELOG gap (the only material hygiene item).**  
   The Unreleased section had detailed coverage for several range deliveries (282 staging fix with full para, 2ecd887 audit model threading, d1d62a6 unmerged filter, 240/246/247/etc., plus broad "Fixed" context for lander/poller/resolver work). Task 283 (the tip agent delivery) had zero mention — no bullet for `ProjectRegistry.upsert/1`, the live Oban queue scaling on replace-or-insert, the distinction vs the existing scalar `dispatch-register_project`, or its role as foundational for the phase-20 Postgres-only edit surface. This is the durable public record; a gap here is exactly the sort of post-merge hygiene an audit catches.

Everything else in the range was clean under the review criteria:
- No dead code left after 272 Legacy sweep (tests + Manifest + ResultStore paths correctly guard/exclude the write-less accessors; import-only paths remain for historical cutover).
- No leftover debug IO or printf-style leakage in core paths.
- No stale "CLI default" text (d3b5a07 already corrected the model cards in-range).
- Toolchain pin + CLAUDE.md note (8d34344/550cd14) landed together; .tool-versions is now the single source (no drift with dev.local guidance yet, because the actual kill-config is future work).
- .harness/ gitignore addition (39179f3 + 282) + bare `git add -A` + targeted reset in Worktree (prevents both review_stuck fatals on gitignored scratch and .harness-retained leakage) — reflected in tree and code.
- Lander changes (prune 275, landed_sha 276, reland 281, resolver 279, task-id guards 280) are narrowly scoped to the described bugs; supporting tests (including blank-line formatting hygiene 0421cc7) and roadmap scope-fence notes are present.
- Test-suite perf bundle (267-271): deterministic sync replacement for sleeps, describe-group splits enabling async:true — focused, no scope creep.
- Routing-brief (273/274/266) + dispatch-compare model override (277) + model catalog unification (265) + per-dispatch model guard (9352613) — surfaces and docs/driver skill updated in the deliveries themselves.
- Audit self-fix (2ecd887) correctly introduces `auditor_model/1` (resolves via Config.agent_model like reviewer; @doc false for testability; falls back to nil for unmappable test doubles) and threads it into the Driver.run invocation. Its own CHANGELOG entry was present.
- Conventions: landed code carries @spec on public functions (multi-clause register/upsert share the union spec above the first head — accepted pattern here), concise moduledocs, no bare TODOs, functional style. Per-edit hooks (format/compile/credo/dialyzer/test.json/doctor/sobelow) already graded every touched file in prior runs.
- No naming drift or inconsistent surfaces (upsert is descripex-annotated and appears via describe-tools; scalar edit tool remains future per phase plan).

**Reviewer-quality feedback loop note (per prompt):** The supplied task-208 rejection (coverage 79.47% < 80% threshold after rescue-pass review) is from a much earlier range (pre-9352613). Not applicable to any commit in this window; noted only as requested. No false-rejection signal to surface for the 27x-283 work.

## Fixes applied (1 file, minimal)
- CHANGELOG.md: inserted a concise Task 283 bullet at the head of the first Unreleased Added block. Matches surrounding tone/length, names the mechanical effects (replace-or-insert, persistence, live queue scale), preserves the create-vs-edit distinction, and cross-references the phase-20 context and existing dispatch scalar. No other files edited — no code changes, no roadmap edits, no expansion of scope.

## Discoveries / rmap filings
None filed. All material follow-ups visible in the range (full Postgres project edit surface, flat dispatch tool for upsert/edit, dashboard card for project config, etc.) are already tracked under the phase-20 roadmap items (283 foundational landed; 284/285 for the kill-config + surfaced editor). No orphaned paths, uncovered edges, or deferred decisions outside the existing plan surfaced during the hygiene pass. (Per rules: only genuine new follow-up work is filed via `rmap new --from-stdin`; this audit produced none.)

## Outcome
Range was otherwise clean. One doc hygiene fix (CHANGELOG) + this report. The audit agent followed the exact prompt contract: reviewed, fixed forward (doc only), wrote report + .harness/audit.json (uncommitted), and produced a single marker commit.

Next audit will use the commit created from this report (`audit(c4ad9b5): ...`) as its base.
