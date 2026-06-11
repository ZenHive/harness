# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Per-project `warm_paths` seed gitignored worktree inputs (Task 252).** `%Harness.Project{}` carries a `warm_paths` list of repo-relative directories (persisted in Postgres via migration `20260611120000`); `Harness.Worktree.warm/2` CoW-clones them from the parent checkout into fresh worktrees alongside the global defaults (`deps`, `_build`, `priv/plts`). Run and audit worktree creation both pass `project.warm_paths` so projects with load-bearing gitignored inputs (e.g. extractor `source/` corpus) don't cold-regenerate on every dispatch.
- **Per-agent default model, operator-configurable (Task 256).** A free-text `{:agent_model, agent}` `:string` Config entry per implementer agent (`Config.agent_model/1`) fills the gap between a task's explicit `model` pin and the agent CLI's ambient default. Implementer precedence is now task `model` → `{:agent_model, agent}` → CLI default (`requested_model` init off `item.agent`); the reviewer — which has no task-pin axis — draws its model solely from the per-agent default for the selected reviewer adapter's agent (`Run.reviewer_model/1`; an unregistered adapter → nil → ambient). A new "Agent models" settings card (`/harness/settings`) edits the values live, reusing the `set_config` event (blank clears to the agent default); `:string` entries route to this card, not the number card. Model ids are unvalidated (they churn — verify against the agent's `--list-models`). An agent outside the schema resolves to nil rather than raising, so a new adapter degrades to the CLI default instead of crashing a run. Task 255 (per-role reviewer override — implement-cheap / review-strong on one agent) builds on this.
- **`/harness/kpi` pivots the per-agent ledger by task-facet (Task 225).** Below the flat fleet-wide tables, the same per-agent facts are grouped by the reviewer-assigned `review_facets` (the routing KEY from Task 224) via `Harness.CapabilityScore.group_by_facet/1`: one card per facet showing each agent's approve% / first-try% / reviewer-quality / mean-tokens / cost-to-green — "who is best at THIS kind of task?", not just fleet-wide. A facet-pill bar filters to one group; the unfaceted bucket always renders. Beside each fact ledger the **scout's written verdict** (`CapabilityScore.read_assessment/1`, Task 216) renders — winning agent + plain-prose reasoning, with the winner's row highlighted — so facts (counted) and AI-written meaning (who to use) sit side by side. The page never recomputes a routing verdict from the numbers (THE MANTRA); a facet with no assessment shows "no scout verdict yet".

### Fixed

- **KPI surfaces `review_stuck` by cause and counts selection-time stuck (nil reviewer_adapter) as orchestration health (Task 249).** `AgentKPI.aggregate_review_stuck_causes/1` + `ResultStore.aggregate_review_stuck_causes/0` (MCP defaulting to configured store) roll `{:review_stuck, detail}` records by persisted cause (`:reviewer_unavailable`, `:no_cross_family_reviewer`, `:same_family_reviewer`, `:reviewer_crashed`, `:driver_crashed`, `:timed_out`, `:cancelled`, `:other`). Dashboard `/harness/kpi` renders an "Orchestration health" table for them (distinct from reviewer reliability, since selection-time failures have no reviewer_adapter). This is harness health, not reviewer attribution.
- **ResultStore MCP read tools resolve `configured()` store when param omitted (KPIs read empty via MCP) (Task 246).** Read tools (`aggregate_by_agent`, `load_batch`, `aggregate_reviewer_reliability`, `aggregate_ceremony_cost`, `get_capability_score`, `list_capability_scores`, `aggregate_review_stuck_causes`) now declare `@configured_store` sentinel as schema default and resolve it to `ResultStore.configured/0` (Postgres or Memory per `:repo_enabled`) instead of `nil` (which shorted to empty/disabled). Sentinel overload clauses + api() updates; tools/MCP callers omitting `store` now see real data. Regression coverage added.
- **Run-lifecycle `in_progress` claim survives concurrent `tasks.toml` writers (Task 245).** Local rmap status writes are now serialized via a `.lock` file (bounded retry acquire under `with_roadmap_lock`) for projects without a durable target; concurrent `mark_in_progress` from run workers can no longer read the same stale snapshot and overwrite each other. Durable (git) path unchanged. Concurrency test in `roadmap_mark_landed_test`.
- **Reviewer selection deprioritizes (never drops) an installed cross-family reviewer when its availability hint is false (Task 247).** `AgentRegistry.available?/1` is a restart-cleared soft latency hint, not a hard gate. `auto_reviewer_modules/1` (and explicit pins) now route through `reviewer_dispatchable?/1` (installed + reviewer_eligible?) and let `prioritize_reviewers/2` + `availability_rank/1` sink a transiently unavailable reviewer to the bottom of the rotation slate instead of `Enum.filter`ing it out entirely. An explicit or auto-pinned cross-family reviewer that the soft hint marks unavailable no longer causes `:review_stuck` before the reviewer ever runs — completed implementer work reaches the gate. Regression tests cover both auto and explicit cases with a deliberately unavailable Codex reviewer.
- **ProjectRegistry.lookup/list are the single boundary for landing-overlaid effective projects (Task 257).** `lookup/1` and `list/0` now apply `Harness.Landing.Settings.overlay/1` at the read edge so every consumer (Run, Lander.Worker, dashboard, MCP) receives the runtime `landing_policy`/`target_branch`/`reviewer` without re-deriving at call sites. The per-site overlays in Run.init and Lander.Worker are gone; a source-invariant test in the registry tests (`overlay/1 is applied at exactly ONE read boundary`) guards against re-introducing the Task 171 pattern. Registration values remain the seed when no operator override exists.
- **AgentKPI quality rollup reads `review_skills` (Task 248).** Since the v0_13 rubric migration the reviewer writes per-skill scores to `review_skills` while legacy `review_ratings` is empty on new runs, so the KPI/dashboard quality column went dark when aggregation still meaned only `review_ratings`. `AgentKPI.record_ratings/1` now prefers non-empty `review_skills` (extracting numeric `score` from each skill block) and falls back to legacy `review_ratings`; the Postgres aggregate path (`ResultStore.Postgres`) collects both fields per run and normalizes through the same helper so Memory and Postgres share the rollup. `Batch.AgentEvaluation` ratings follow the same precedence.
- **Boot-time fail-fast on pending Ecto migrations.** `Harness.Repo.MigrationGuard` runs once after `Harness.Repo` when `repo_enabled: true` and raises if any migration is `:down` — a forgotten `mix ecto.migrate` aborts boot instead of silently emptying `Harness.ProjectRegistry` via the persistence layer's soft rescues (motivated by the `warm_paths` column drift incident). `ProjectRegistry.Persistence` now re-raises Postgrex `undefined_column`/`undefined_table` errors instead of swallowing them into an empty registry.
- **`dispatch-await` accepts float `timeout_ms` from MCP/JSON callers (Task 253).** JSON deserialization delivers numeric params as floats; `Dispatch.await/5` and `await_result/2` now guard with `is_number/1` and `trunc/1` at the boundary instead of rejecting with a function-clause error. `Harness.Chat.Tools` decodes JSON-string-encoded keyword-list params (e.g. `list_run_records` filters sent as `"{\"agent\": \"cursor\"}"`) by parsing Jason JSON before atomizing keys — same contract as map-shaped keyword params.
- **Reviewer-only agent was unexpressable; sank every run on a reviewer-only-pinned project.** `Harness.Run.reviewer_dispatchable?/1` ANDed in the implementer-level `AgentSettings.enabled?` gate alongside `reviewer_eligible?`, so a Claude pinned as the dedicated reviewer but disabled as an implementer (`enabled? == false` + `reviewer_eligible? == true`) was rejected as `{:reviewer_unavailable, Claude}`, settling every run `:review_stuck` on a project whose persisted `LandingSettings` pin Claude reviewer-only. The two operator flags are orthogonal — `enabled?` governs IMPLEMENT, `reviewer_eligible?` governs REVIEW — so reviewer-dispatchability now keys on `reviewer_eligible?` alone among the operator gates. Dropped the unused `reviewer_enabled?/1`; exposed `reviewer_dispatchable?/1` as `@doc false def` for the regression test. To bar an agent from both roles, turn off both flags.
- **Duplicate migration version silently dropped two `run_records` columns.** Two
  parallel dispatches each stamped a migration `20260605010000`
  (`add_review_skills_to_run_records` + `add_reviewer_fallback_counts_to_run_records`);
  Ecto keys `schema_migrations` by version integer, so once `add_review_skills` ran the
  fallback-counts migration was permanently skipped — `reviewer_reprompt_count` /
  `reviewer_rotation_count` never got created. The `RunRecord` Ecto schema selects both,
  so every `ResultStore.list_run_records/0` (and the AgentKPI / dashboard reads built on
  it) crashed with `column r0.reviewer_reprompt_count does not exist`. Renamed the skipped
  migration to a unique version `20260605011000` so it runs; the two columns now exist and
  the Postgres result-store read path is healthy again.
- **Pinned model now actually reaches the agent CLI (Task 240).** `requested_model` (from the rmap task's `model` field, already threaded into Run data, status, LogRecord, and ResultStore by Task 42) is now copied into the `%Invocation{}` built for the implementer path (`invocation/3`) and the recovery/resume path (`recovery_invocation/1`). Before the fix, both builders omitted the key so `AgentAdapter.model_args/1` always saw the struct default (nil) and no `--model` flag was ever emitted — every run (cursor, codex, etc.) used the agent's own default regardless of an explicit Opus (or other) pin on the task. Observed live on a cursor+Opus dispatch for Task 234. Reviewer and resolver invocations remain deliberately unpinned (cross-family judgment roles). Added regression coverage in `run_test.exs` via a `:capture_model` FakeAdapter fixture that writes the received `invocation.model` (or empty) into a committed file for post-settle git-show assertion. Pure pass-through fix; no new surfaces.

### Added

- **Audit + lander lifecycle visible on `/harness` (Task 243).** The dashboard's `RunFeed` is driven solely by the `Harness.Run` gen_statem, so only the implementer/reviewer/recovery STAGES of a run reached the dashboard — the post-merge audit (`Harness.Audit`, a real third-family agent run) and every land operation (`Harness.Lander`: rebase / ff-push / conflict→resolver / blocked-by-cap) run as separate Oban workers and were invisible (operator: *"i only see implementer runs, but i can not see audit runs and all the other things"*). New `Harness.Dashboard.OpsFeed` (PubSub-guarded, mirrors `RunFeed`) carries fact-only `Harness.Dashboard.OpsFeed.Op` events on a distinct `harness:ops` topic — so they never masquerade as `%Run.Status{}` rows and the Active/History tables stay run-only. `Harness.Audit` broadcasts `started` (auditor selected) + `settled` (with the agent's capped transcript), `Harness.Lander` broadcasts `landing` / `landed` / `conflict` / `resolving` / `push_rejected` / `skipped`, and `Harness.Lander.Resilience` broadcasts `blocked` at the land-cap. The LiveView subscribes and renders a dedicated, bounded (40-row, newest-first) "Audit & land ops" panel; settled audits carry an expandable transcript. Mantra-clean: the feed COUNTS facts (stage, agent, sha, range, outcome) and only relays the audit's own `.harness/audit.json` verdict — it never recomputes meaning.
- **Cron manual-approval dispatch mode (Task 237).** A per-project cron **dispatch mode** — `:auto` (default) | `:manual` — joins the existing on/off `:cron_project_autonomy` boolean as a third, orthogonal dimension in `Harness.Cron.Settings` (`dispatch_mode/1` reader, `set_dispatch_mode/3` setter with actor audit log, write-through persistence + `load_into_env/0` seeding; absence ⇒ `:auto`, so existing autonomous projects keep auto-dispatching unchanged). Under `:manual`, the poller parks its resolved dispatch decision (task id + adapter + env scrub) at the single enqueue boundary both autonomous paths share (the 1-task `direct_dispatch` and each ≥2-task orchestrator-plan entry) instead of calling `Worker.enqueue` — the orchestrator AI still makes every judgment; the gate only holds the mechanical enqueue. Parked decisions live in the new `Harness.Cron.PendingDispatch` store (idempotent over `{project, task}`, atomic claim-on-approve so double-enqueue is impossible); a `:dispatch_parked` `Harness.Notification` witness event fires on park. Operators drain them via the new `dispatch-pending` (list) and `dispatch-approve` (enqueue) MCP/chat tools. Interactive `dispatch-task` / `dispatch-await` are never gated — only the cron path is.
- **Per-approved-run ceremony / fragmentation tax measurement (Task 234).** `Harness.AgentKPI.aggregate_ceremony_cost/1` (and `ResultStore.aggregate_ceremony_cost/2`) counts raw implementer + reviewer (parsed from `reviewer_output`) + audit (0 until capture lands) token spend for every reviewer-approved (`:approve` + `:done`) run record. Returns per-task breakdown plus median/p90 distribution over totals and components — pure counting of the per-dispatch overhead facts already persisted; no batching verdict or recommendation. Requires `include_transcripts: true` (via the store wrapper) so reviewer transcripts are retained for parsing. Exposed as `result_store-aggregate_ceremony_cost`; documented on the driver surface.
- **MCP dispatch-hold boolean-arg coercion + hold→steer→resume recovery contract (Task 238).** `Harness.Chat.Tools` now coerces string / wrapped-boolean values for `boolean()`-schema params before schema validation and apply (covers MCP JSON callers that send `"true"`, `{"value": false}`, etc.). The `interrupt` param on `dispatch-hold` (and the backing `api()` entry) declares `schema: boolean()` so the coercion applies. Driver skill updated with the live recovery loop: `dispatch-hold` with `interrupt: true` → `dispatch-steer` → `dispatch-resume` for force-handoff of a grinding implementer (reviewer still gates; implementer does not need to green checks before handoff).
- **Implementer-phase idle watchdog (Task 239).** `:running` state now arms a gen_statem `state_timeout` idle watchdog (floored at 10 min so a silent compile/test/dialyzer does not trip it; explicit lower values are raised, higher values and `:infinity` win). Output chunks re-arm it (once the agent handle is captured). On expiry the run settles with `{:timed_out, :idle}` outcome exactly as reviewer idle does; the reviewer still gates. `Run.implementer_idle_timeout/1` is public `@doc false` for test; an explicit `:implementer_idle_timeout` run opt bypasses the floor for mechanics tests. Extracted `settle_implementer_outcome/2` to keep the running handler small.

- **ResultStore.File + Chat.Store.File retired; Postgres/Memory default split (Task 212).**
  `Harness.ResultStore` and `Harness.Chat.Store` now default from `:repo_enabled`:
  `Postgres` (durable) when true, in-memory ephemeral `Memory` when false. The
  `File` backends, their term-file layout under `~/.harness/{results,chats}`, and
  the associated root config keys are deleted. `LegacyTermImport` (started only
  for repo-enabled nodes) plus `mix harness.import_results` provide a one-time,
  idempotent cutover of existing `.term` data into Postgres on first boot for
  self-hosts. Consumer template updated (`d674ca9`). Explicit
  `:result_store` / `:chat_store_backend` overrides still win; ephemeral mode is
  reflected in ConfigInspector ("memory:ephemeral") and the shared flash banner.
  KPI parity and restart-survival tests cover both backends.

- **Hard-fail pollution paths removed after recovery + retry seam (Task 230).**
  With bounded mechanical recovery for checkout pollution (Task 229) and
  substrate retry (Task 227) proven in production, the remaining short-circuit
  paths in `Harness.Run` (driver `:DOWN`, timeout, terminate) that turned a
  witnessed main-checkout pollution into an immediate hard `:failed` are
  deleted. Pollution now routes through the per-run recovery AI (with budget)
  before any terminal advance; only unrecoverable cases or reviewer rejection
  settle failed. Added `PollutingCrashAdapter` coverage exercising the crash
  + pollution → recovery path.

- **Tier-1: bounded mechanical retry on transient substrate ops (Task 227).**
  `Harness.Run` and `Harness.Worktree` now retry a bounded number of times on
  transient `{:error, _}` results from worktree git ops (`create`, `commit`,
  target fetch) and the agent Port spawn path (`Driver.run`) before the run
  settles the failure. A new `Harness.Run.RetryPolicy` supplies the arithmetic
  (knobs from `:harness, :retry_policy` app config or per-dispatch
  `:substrate_retry`); the wrappers are purely mechanical — only ever retry
  substrate `{:error, _}`, never inspect agent output, never re-dispatch a settled
  run, and carry no English-string classifiers (enforced by source invariant test).
  Run's `commit_worktree` wrapper disables the inner Worktree retry (`max_retries:
  0`) to avoid double backoff on the (diff_size + commit) compound. All judgment
  about what a transient substrate failure *means* stays with the cross-family
  reviewer. Witnessed as raw policy application at the call sites.

- **Cron-as-orchestrator-AI: full-context dispatch planning gated by a mechanical
  upside-count (Task 233).** `Harness.Cron.RoadmapPoller` no longer encodes the
  next-task / grouping / routing decision in code. Each tick a pure count (the
  mantra's "count facts in code") classifies the dispatchable ready set: 0 →
  nothing, 1 → direct dispatch by `assignee`, ≥2 → wake the new
  `Harness.Cron.Orchestrator` — a full-context cross-family AI (default `:codex`,
  configurable via `config :harness, :cron_polling, orchestrator_adapter:`) that
  reads the ready set (bodies/scores/touches/markers/assignee) + in-flight task
  touches + capability facts and writes `.harness/cron-plan.json`
  (`{"dispatch": [...], "skip": [...]}`). Harness reads the plan mechanically —
  validates each task is in the woken set, resolves the adapter, enqueues — and
  decides nothing about grouping; the touch-disjoint / stale-base-avoidance /
  honor-assignee / Opus-last judgment lives entirely in the plan artifact. The
  retired `@default_agent = :claude` no longer defaults unrouted work to Opus: a
  missing or `human` assignee carries no dispatch intent and is logged + skipped.
  An empty/malformed/agent-failed plan dispatches **nothing** that tick (never a
  blind fan-out — that was the 2026-06-05 stale-base collision); wave-pacing falls
  out of the cron cadence + the dedup window, with no wave-tracking state in code.
  `Harness.Roadmap.ready/1` gains a `:fields` opt (default unchanged) so the
  orchestrator receives full task context. The per-project Oban `concurrency_cap`
  stays the mechanical ceiling the plan cannot override.
- **Review-only salvage primitive — re-review a retained branch (Task 236).**
  `Harness.Dispatch.rereview/1` (MCP `dispatch-rereview`) and the `review_only?`
  run path let a driver re-enter the reviewer gate on a settled run's retained
  `harness/<run-id>` branch without re-running the implementer. The run routes
  directly from `:dispatched` to `:reviewing` (skipping the agent leg), carries
  forward the prior `agent_diff_size` for KPI, and is still fully gated by a
  cross-family reviewer that produces a fresh `.harness/review.json` verdict.
  Distinct from `resume_failed` (which continues the implementer from the branch
  + injects the prior report). Mechanical wiring only; all judgment stays with
  the reviewer AI.
- **Bounded, witnessed AI-recovery seam for checkout pollution (Task 229).** `Harness.Run`
  routes the one genuinely interpretive non-rejection failure (implementer checkout
  pollution) through a per-run budgeted (default 1) cross-family recovery AI before
  hard-failing. Recovery AI gets minimal context only (reason + main-checkout git status
  + transcript tail + check output), writes `.harness/recovery.json` (`"outcome":
  "repaired"|"dead"`, report, optional short repaired note). `repaired` resumes at
  `:committing` (re-runs full reviewer gate); `dead`/missing/malformed settles `:failed`
  with original reason. Reviewer rejects bypass recovery entirely. New transient
  `:recovering` state (surfaces as `:repairing` in StatusView/dashboard like
  `:reviewing`). Witness fields (`recovery_attempts`/`_outcome`/`_repaired`/
  `recovery_token_usage`) on `Result`, `LogRecord`, and Postgres `run_records` (raw
  facts persisted for witness metrics; `recovery_token_usage` proves two-tier recovery
  is cheaper than hard-fail + re-dispatch). Mechanical artifact read; all judgment in
  the recovery AI. Includes hardened terminate/cancel/memory paths for the recovery
  slot and `checkout_pollution_check` opt. Credo-strict line-length follow-up in same
  delivery.
- **Per-facet scout-AI competence assessment replaces CapabilityScore composite + routing arithmetic (Task 216).**
  The old composite scalar (hand-tuned weights over ratings/cost/fix-size, stale discount,
  explore/exploit branching on freshness, corpus fingerprint) is deleted. In its place:
  raw run records (now carrying reviewer `review_facets`) are grouped mechanically;
  per-agent facts are rolled by the unchanged `AgentKPI`; a cross-family scout AI (default
  codex) is spawned on demand or via `dispatch-assess_facets` / `CapabilityScore.refresh/1`
  to write a per-facet assessment artifact (`.harness/facet-assessment.json`) with winner +
  prose reasoning for each task-kind. `dispatch-recommend` (and the cron orchestrator context)
  matches an incoming task's facets against that artifact and returns the scout's choice +
  rationale (`:exploit`) or a safe `:explore`/fallback when the facet is unmeasured or no
  assessment exists yet. Legacy `{agent, domain, corpus_version}` composite cells remain
  import-only via `CapabilityScore.Legacy`, the `capability_scores` ResultStore callbacks,
  and `LegacyTermImport` (for historical term data cutover); active routing never reads or
  writes them. `AgentKPI` untouched. No magic weights, no freshness arithmetic, no
  re-benchmark scheduler remain in the routing path. Decoder hardened in review (agent
  whitelist, tagged results, no untrusted atom creation). Tests cover facet grouping,
  assessment round-trip, unknown-winner rejection, dispatch matching, and refresh wiring.
- **Reviewer-stage mechanical fallbacks (Task 228).** Generalize Task 203's missing-verdict
  re-prompt to *unreadable* verdict artifacts (missing *or* malformed `.harness/review.json`) —
  one bounded mechanical re-issue of the write in the same worktree before honest
  `{:review_stuck, ...}`. On reviewer spawn/idle timeout, rotate to the next eligible
  cross-family reviewer from the finite candidate slate carved at `route_to_review`
  (auto: registry minus implementer family, rejection-rate prioritized for rotation order;
  explicit `reviewer: [M1, M2]` supplies operator rotation sequence). Both fallbacks are
  mechanical (no content-based recoverability judgment) and witnessed as raw facts
  (`reviewer_reprompt_count`, `reviewer_rotation_count`) on `Run.Result` / `LogRecord` /
  persisted `run_records` (plus migration + codec + contract tests). Delivery includes
  `select_reviewers/1` (returns `[primary | candidates]`), `rotate_or_fail_review/2`,
  updated reprompt prompt, and the rotation tests (HangingAdapter, SpawnThenIdleReviewer
  doubles). Same-batch repair: recovering seam updated for the rename; LogRecord 34-field
  credo disable with mantra comment (recovery facts). Config: dev `concurrency_cap` lowered
  10→3 with rationale (stale-base divergence + shared reviewer pool under wide dispatch).
- **Oban Lifeline rescues orphaned landing/audit jobs (Task 209).** Open-source Oban
  does not move `executing` rows back to `available` when a worker dies mid-land or
  mid-audit — a BEAM restart left onchain landing job 294 stuck `executing` for
  25+ minutes. `Harness.Oban` now registers `Oban.Plugins.Lifeline` with a
  30-minute `rescue_after` window (longer than any legitimate land/audit) so stale
  `landing_*` and `audit` rows retry automatically. Complements the boot-time
  `Run.Worker` orphan sweep (Task 160) without replacing it.
- **Audit watermarks in the Postgres settings store (Task 211).** Clean audits
  (`:no_changes`) no longer need an empty `audit(...)` marker commit on the shared
  branch — harness records the audited tip in `Harness.SettingsStore` under
  `:audit` (with a one-time import from `~/.harness/audit_watermarks.term`).
  `repo_enabled:false` keeps watermarks ephemeral like other settings.
- **Reviewer rubric: facets (routing KEY) + skills (routing VALUE) in review.json
  (Task 224).** The cross-family reviewer now writes open-vocabulary `facets`
  (ground-truth task characterization from spec + diff) and `skills` (two-axis
  `{score, note}` rubric) alongside the legacy flat `ratings`. Harness persists
  both verbatim; no fusion into capability scores in code.
- **In-run discernment reads rmap d-score + markers structurally (Task 218).**
  `Harness.Roadmap.Item` carries `d` and `:security`/`:bug` markers from rmap;
  `Harness.Run.discernment_weight_passes?/3` gates sampled transcript review on
  those facts instead of prose regexes over task titles/bodies.
- **Mechanical worktree warming at provision (Task 226).** `Harness.Worktree`
  seeds `deps/`, `_build/`, and a cold PLT into new run worktrees so the
  reviewer's first `mix precommit` is not paying a full cold compile every dispatch.
- **Shared git non-fast-forward detection (Task 221).** New `Harness.Git.non_fast_forward?/5`
  dedupes the lander and `Roadmap.Durable` push-rejection triplet: prefers
  `fetch` + `merge-base --is-ancestor` over matching git's English output, with
  documented text fallback when plumbing is inconclusive.
- **Run landed-state reconciliation against the target branch (Task 214).** Dashboard
  merge labels no longer equate "no roadmap `shipped_in`" with "not merged". Roadmap
  writeback remains the fast witness; when absent, `Harness.Dashboard.RunFeed.landed_sha/3`
  falls back to git facts — the run's `harness/<run-id>` branch tip reachable from
  `origin/<target_branch>`, or a rebased delivery commit located by the standard
  `(run <run-id>)` message suffix on the target branch. Fixes false "approved but
  not landed" for direct-commit and manual-landing work already on the target.
- **AgentKPI attributes review_stuck to the reviewer, and tracks per-reviewer
  verdict-write reliability (Task 231).** A `{:review_stuck, _}` run (the
  reviewer ended its turn without writing `.harness/review.json`) is the
  *reviewer's* failure, not the implementer's — yet it sat in the implementer's
  `success_rate` denominator as a non-pass, mis-routing future dispatch through
  `Harness.CapabilityScore`. Both rollups now exclude it from the implementer's
  denominator (`attributable_count = run_count − reviewer_flaked`) and surface
  the count as a separate `reviewer_flaked` field; the Postgres SQL fast path
  mirrors the in-memory rollup (KPI parity preserved). The per-reviewer ledger
  (`AgentKPI.aggregate_reviewer_rejections/1`) gains `no_verdict_count` /
  `no_verdict_rate` alongside the rejection rate — the reviewer's verdict-write
  reliability, the signal needed to prefer reliable reviewers. Surfaced on the
  `/harness/kpi` dashboard (a `Rvw flaked` column + a worst-first *Reviewer
  reliability* table) and the MCP KPI surface
  (`result_store-aggregate_reviewer_reliability`). Pure counting + mechanical
  attribution keyed on the persisted `reason` fact — no classifier, no
  "whose-fault" heuristic.
- **Reviewer transcript + outcome now persisted on every run record (Task 232).**
  harness persisted the *implementer's* raw transcript (`agent_output` + kind /
  exit_status) but discarded the *reviewer's* — its `%Outcome{}` was
  pattern-matched and thrown away in the `:reviewing` settle path. So a
  `{:review_stuck, _}` run (the reviewer exited without writing
  `.harness/review.json`) left no record of *what the reviewer did* before
  omitting the verdict, blocking any root-cause of the recurring cross-family
  stuck rate. `Harness.Run.Result` now carries `reviewer_outcome`, and
  `Harness.Run.LogRecord` mirrors the implementer fields with `reviewer_output`
  / `reviewer_outcome_kind` / `reviewer_exit_status` (Postgres columns +
  migration; both raw-transcript blobs are stripped from list scans and
  returned only on a single-`run_id` point lookup). The dominant stuck mode is
  a *clean* reviewer exit, so the captured transcript is the diagnostic. Pure
  mechanical capture — facts persisted for an AI to read, no judgment in code.

### Fixed

- **Reflex watchdog no longer false-halts on benign temp cleanup (Tasks 219, reflex
  follow-up).** Deleted the dead `verification_stack_edit?` grade-gaming blocklist
  (reviewer-owned judgment per agent-gate). The reflex layer now ignores
  `rm -rf`/`unlink` on harness temp-scratch paths and worktree-sweeper tokens so
  agents cleaning `_build` or tmp dirs are not reflex-halted mid-run.
- **Roadmap status transitions are now git-durable (Task 215).** harness's dispatch
  lifecycle mutates the *canonical* `roadmap/tasks.toml` (`in_progress` at dispatch
  start, `done`/`pending`/`blocked` at settle), but historically treated those as
  uncommitted local-file writes — so every run silently raced every other session
  and cloud agent against the shared file, and a stale copy could clobber a
  concurrent writer's edits (rmap's validate-then-write guards *invalid* writes,
  not *lost* ones). New `Harness.Roadmap.Durable` makes each transition a durable
  git op: fetch the project's `target_branch` → mutate a fresh detached worktree at
  the `origin/<target>` tip → commit (`roadmap: task <id> -> <status>`) → ff-push
  (non-ff re-fetches, replays the mutation on the winner's tip, and retries up to a
  cap — never `--force`) → fast-forward the operator's *local* target via the
  shared `Harness.Git.TargetSync` (ff-only, never touching a dirty/diverged
  checkout) so on-disk `tasks.toml` doesn't drift behind origin. All four
  `Harness.Roadmap.mark_*` mutators funnel through one `mutate/4` chokepoint;
  durable when a `%Harness.Project{}` with a `target_branch` + local source is
  passed, else the historical local rmap write. `TargetSync` is extracted from the
  lander's post-push sync and reused by both. Mechanical substrate only — no
  judgment branch added to harness code.
- **Subscription billing: scrub provider API keys from spawned agent CLIs.** Each
  agent CLI is spawned as a Port that inherits the BEAM's environment, so a stray
  `ANTHROPIC_API_KEY` (Claude) or `OPENAI_API_KEY` (Codex) silently diverted
  billing from the operator's interactive subscription to the API — and an
  empty-balance key failed the run outright ("Credit balance is too low"),
  producing `:review_stuck` on every Claude-reviewer run. New
  `Harness.AgentAdapter.Capabilities.auth_env_scrub` lists the auth vars an adapter
  must unset; `Harness.AgentAdapter.invoke/2` drops them from the Port env
  (`{key, false}`) before spawn. Claude scrubs `ANTHROPIC_API_KEY` /
  `ANTHROPIC_AUTH_TOKEN`, Codex scrubs `OPENAI_API_KEY`; per-CLI verification
  (Task 205) added `CURSOR_API_KEY` (Cursor) and `XAI_API_KEY` (Grok), while
  Antigravity and Pi intentionally declare none (subscription-OAuth CLIs with no
  single billing-diverting key — documented at each adapter's `capabilities/0`).
- **Antigravity worktree isolation regression (Task 198).** `agy` ignores Port `cwd`
  for file writes; `Harness.AgentAdapter.Antigravity` now passes `--add-dir <worktree>`
  in `build_command/1` (mirrors Codex `exec --cd`, Task 41). Reverts the incorrect
  Task 187 claim that port cwd alone was sufficient.
- **Audit 5e3941b: chat session migration shape.** The `chat_sessions.messages`
  migration now creates the same `{:array, :map}` column type that
  `Harness.Chat.Store.Postgres.ChatSession` inserts.
- **Task 203: reviewer missing-verdict recovery.** A reviewer that finishes its
  review but exits without writing `.harness/review.json` is now re-prompted ONCE
  in the same worktree with a terse "write the verdict now" nudge before the run
  is discarded — recovering the full implementer+reviewer spend on a recoverable
  miss (`Harness.Run` `settle_review/2` on `{:error, :missing}`, bounded by a
  `reviewer_reprompt_count` counter; `:repeat_state` re-arms the spawn/idle
  watchdogs identically to the first pass). The re-prompt is mechanical — a
  re-issued flush of the artifact the reviewer owed, interpreting no work — so it
  stays inside the agent-gate rule. Malformed verdicts and rejects are unchanged;
  a second miss settles `:failed` as `{:review_stuck, ...}` exactly as before.

### Changed

- **rmap failures classified by structured exit code, not English stderr (Task 220).**
  `Harness.Roadmap.classify_failure/2` previously regex-matched rmap's English
  stderr (`~r/task .+ not found/i`, `String.contains?(output, "invalid TOML")`) to
  decide `:task_not_found` vs `:roadmap_not_found` — fragile against wording/locale
  drift, and meaning-from-prose for a CLI harness *owns* (`../rmap`). Fixed at the
  source: rmap now exits **3** for task-not-found and **4** for an
  unreadable/missing/malformed roadmap (`tests/cli.rs` covers both); harness matches
  on the exit code. Semantic validation errors keep the generic code and still fall
  to `{:rmap_failed, …}`. The classifier carries no regex anymore — the meaning lives
  in rmap's exit-code contract.

### Added

- **Task 207: configurable default dispatch agent.** A new operator-config key
  `{:dispatch, :default_agent}` (`:agent`-typed, UI-editable, default `:codex`)
  sets which implementer an unassigned roadmap task default-routes to — replacing
  the hard-coded `:claude` fallback. `Harness.Config.dispatch_agents/0` exposes the
  validation set (the implementer agents minus `:human`) that both the `:agent`
  type and the dashboard Settings select draw from; `Harness.CapabilityScore` reads
  the key as the `dispatch-recommend` fallback agent. Configurable from the Settings
  LiveView. Tests cover the config round-trip, the agent-set validation, and the
  settings-select wiring.

- **Task 204: dashboard Resume + Re-land recovery buttons.** Settled runs now
  carry two confirm-gated recovery affordances, each surfaced only when the run's
  state permits it (agent-gate: harness offers, the operator chooses; no
  auto-classification). **Resume / Escalate** on a `:failed` run re-dispatches its
  roadmap task on a new run branched off the retained `harness/<run-id>` branch —
  the prior attempt's commits are the starting point, with the failure report
  injected into the prompt — reusing the original agent ("Resume") or escalating to
  the capability-recommended agent ("Escalate") (`Harness.Dispatch.resume_failed/2`; a new
  `:base_ref` start-run opt threads the branch base through `Harness.Run`'s
  `worktree_opts/1`). **Re-land** on a run whose land-train hit its cap and left
  the task `blocked` re-enqueues the landing job
  (`Harness.Dispatch.reland/1` → `Harness.Lander.enqueue/1`, gated on
  `Harness.Dashboard.RoadmapSummary.blocked?/3`) — the branch is already
  reviewer-approved, so it spends **zero agent tokens**. Both also exposed as MCP
  tools `dispatch-resume_failed` / `dispatch-reland`.
- **Task 167: declarative operator-config schema + UI-editable run timeouts.**
  `Harness.Config` (+ `Harness.Config.Entry`) centralizes the operator-relevant
  `:harness` app-env keys — each declaring its key path, baked-in default, type,
  overriding env var, and `ui_editable?`/`restart_required?`/`secret?` flags — so
  defaults live in one place (`schema/0`) instead of scattered `@default_*`
  attributes. `get/1` is the schema-backed read path; `put/3` validates, persists
  through `Harness.SettingsStore`, and hot-applies to app env unless the key is
  `restart_required?` (a set env var wins over a persisted override on boot, via
  `load_into_env/0`). `Harness.Dashboard.ConfigInspector` now renders from the
  schema (only the result/settings store sections stay derived); `SettingsLive`
  gains an editable card for the run timeouts + dashboard port, with
  restart-required keys labeled deferred-until-boot. `Harness.Run` routes its six
  timeout reads through `Config.get({:run, key})`.
- **Task 200: per-run memory watchdog bounds spawned process trees.**
  `Harness.Run.MemoryGuard` samples the resident memory of a run's spawned OS
  process tree (the Port'd agent CLI + every descendant, including the
  `check_command` `mix`/`cargo` the reviewer AI runs) on a timer; a tree past a
  configurable ceiling (default 6 GiB) is SIGKILL-reaped whole and the run
  settles `:failed` with `{:memory_runaway, info}`. Fixes the 2026-06-04 double
  host-OOM, where an "onchain" reviewer check beam ran away to ~27 GB (kernel
  watchdog panic + jetsam) while `OSProcess.kill/1` reaped only the immediate
  pid and orphaned the grandchild. Mechanical substrate only — `ps`/`kill`, no
  output parsing, no change to the reviewer verdict contract. Overridable via
  `config :harness, :run, mem_threshold_kb:`/`mem_sample_interval:`.
- **Task 140: chat session store is now a behaviour + facade with a Postgres
  backend.** `Harness.Chat.Store` is converted from a concrete file-backed module
  into a facade over the `@callback save/3` · `load/2` · `list/1` behaviour
  (mirroring `Harness.ResultStore`). `Harness.Chat.Store.File` holds the original
  atomic-`.tmp`-rename / 200-message-cap / tolerant-read logic verbatim;
  `Harness.Chat.Store.Postgres` (+ `Harness.Chat.Store.Postgres.ChatSession`
  schema, `chat_sessions` table) is new. The backend is selected via
  `config :harness, :chat_store_backend` (default `File`, so existing
  file-backed behaviour and the `:chat_store` root/disable config are unchanged);
  call-time opts override configured backend opts. The Postgres `load/list`
  decode restores atom keys with `String.to_existing_atom` + binary fallback (no
  atom-table DoS). Salvaged from an antigravity run that built the backends but
  left the facade unwired; the facade + tests were hand-finished. The Postgres
  backend's error-rescue + JSON-decode paths are now graded by the **default**
  (non-`:integration`) suite via an in-process `FakeRepo`
  (`test/harness/chat/store/postgres_codec_test.exs`, mirroring
  `ResultStore.PostgresCodecTest`), bringing all three Chat.Store modules over the
  80 % coverage gate (Postgres was 0 % in the gated run — only an `:integration`
  round-trip exercised it).
- **Task 104: harness-workflow promoted to global includes.** `priv/includes/harness-workflow.md` is the version-controlled source for the generalized harness delegate/verify/repair/land workflow (extracted from the incubator `docs/dogfooding-workflow.md`). New `mix harness.install_includes [--dest DIR] [--force]` installs (or updates with .bak) to `~/.claude/includes/harness-workflow.md`. Any repo adopts the normal way: `@~/.claude/includes/harness-workflow.md` (layered, does not supersede workflow-philosophy / task-prioritization / worktree-workflow). References, CLAUDE.md load-on-demand, SKILL.md, README, and in-repo recipe updated. Tests cover install paths.
- **Reviewer KPI ratings feed AgentKPI/CapabilityScore + reviewer
  rejection-rate tracking (Task 177).** `AgentKPI.aggregate_reviewer_rejections/1`
  rolls run records up by `reviewer_adapter` into a per-reviewer rejection
  ledger, and `AgentKPI.rating_means/1` means the reviewer's numeric rating
  keys. `CapabilityScore` gains a `mean_ratings` field and a ratings-tiebreaker
  term (weight 0.5, sub-success_rate): since approval is near-constant by
  design, reviewer-judged quality is what moves `dispatch-recommend` routing
  within a same-success cohort. `Harness.Run.prioritize_reviewers/2`
  deprioritizes (never blacklists) cross-family reviewers with a high historical
  rejection rate. `Harness.Audit` now feeds the auditor the project's recent
  reviewer rejections so it can flag FALSE rejections — report-only, never a
  revert.
- **Lander merge-conflict resolver agent (Task 189).** A rebase conflict during
  an auto-land no longer dead-ends straight into a fresh re-dispatch (which
  discards a reviewer-approved diff and reruns the implementer blind). The
  lander now leaves the detached landing worktree mid-rebase (markers in place)
  and hands it to a cross-family merge-resolver agent — `Harness.Lander.Resolver`
  — that reconciles the markers (default: keep both additive sides), then
  harness mechanically `git add`s, asserts **zero** leftover conflict markers
  (`git diff --cached --check`), and runs `git rebase --continue` before the
  existing ff-push. The resolver is an *attempt, never a gate*: it does not
  re-run the project checks or re-grade the diff (the reviewer already approved
  both sides), and any failure — no eligible cross-family resolver, the agent
  declines, markers still present, or `rebase --continue` rejecting — aborts the
  rebase and falls back to the existing `{:conflict, _}` → re-dispatch path. **A
  still-conflicted tree is never landed.** Resolver selection reuses the
  reviewer-eligibility/registry discipline (family ≠ implementer; prefers the
  run's own approving reviewer). Injectable via the `:lander_resolver` env (like
  `:oban_insert`) so the suite exercises the git finalize without spawning a CLI.
- **Per-agent reviewer-eligibility toggle, distinct from implementer enable
  (Task 182).** `Harness.Agent.Settings` gains `reviewer_eligible?/1`,
  `reviewer_ineligible?/1`, `reviewer_ineligible_agents/0`, and
  `set_reviewer_eligible/3` — a second, independent axis from the existing
  enabled (implementer) flag, so an agent can implement yet be ineligible as the
  cross-family review gate. Persisted as a `reviewer_ineligible` set in
  `agent_settings.term`, seeded from the `:reviewer_exclude` config (default
  `[:pi]`) until an operator override is written; `persist/0` only materializes
  the set once a real override sets the env key, so the config seed stays live
  until then. `Harness.Run`'s reviewer selection now consults
  `reviewer_eligible?/1` (the static `reviewer_excluded?` denylist is deleted;
  `:reviewer_exclude` is no longer read in `run.ex`). The dashboard settings
  page renders a per-agent enabled + reviewer toggle matrix.

### Security

- **Push-neuter in harness-created run worktrees (Task 186).** An in-run agent
  has a full shell in its worktree and could run `git push` / `gh pr create` to
  reach origin on its own initiative, bypassing the lander — the only place
  MERGE is meant to happen (observed on the rmap `:manual` project: in-run work
  reached GitHub and had to be pulled back). `Harness.Worktree.create/2` now
  enables `extensions.worktreeConfig` and sets `remote.origin.pushurl` to a
  `/dev/null` sentinel via `git config --worktree`, scoped to the run worktree's
  `config.worktree` only — an in-run `git push` fails locally with no network
  call. Fetch, the operator's main checkout, and the lander's detached worktree
  all still push. Best-effort (a config failure logs and proceeds). **Does not
  cover the `gh pr create` vector** (uses the gh token, not the git remote) —
  tracked as a follow-up.

- **GitHub auth isolation for in-run agents (Task 188).** In-run invocation env
  now forces `GH_TOKEN` and `GITHUB_TOKEN` to `{key, false}` scrub pairs before
  spawning implementer, reviewer, or recovery agents, closing the `gh pr create`
  token vector left open by Task 186's push-neuter. Decision recorded: token
  scrub alone is **not sufficient** to fully block ambient `gh` auth because
  GitHub CLI can also read `~/.config/gh/hosts.yml`; broader isolation is
  warranted, so harness also pins `GH_CONFIG_DIR` to the run-local
  `.harness/gh-config` path. This removes operator `gh` auth from the ambient
  in-run environment while leaving Task 186's worktree-scoped `git push`
  sentinel responsible for the separate git transport path.

- **Dashboard run-history Delete button + `ResultStore.delete_run/2`.** Settled
  rows in the "Run history" table now carry a confirm-gated **Delete** action
  that discards the run's persisted record (e.g. throwaway smoke runs that
  shouldn't clutter the index or skew KPI rollups). New behaviour callback
  `Harness.ResultStore.delete_run/2` (idempotent — an absent record returns
  `:ok`) implemented by both the File and Postgres backends and exercised by the
  shared `ResultStoreContract`. The function is **deliberately not**
  `api()`-annotated: `ResultStore` is in the Manifest driver surface, so an
  annotation would expose a destructive write to the orchestrator MCP/chat tool
  list — it stays dashboard-operator-only until an orchestrator use case asks
  for it.

- **The agent-gate workflow rebuild (hand-built, 2026-06-03).** The run
  lifecycle is now `worktree → implementer AI → reviewer AI (THE gate) → MERGE
  → audit AI`, with **no mechanical verification gate anywhere** — the
  cross-family reviewer AI runs the project's checks itself, fixes inline, and
  writes the verdict; harness reads it mechanically. New modules/surfaces:
  `Harness.Run.Review` (parses the reviewer's `.harness/review.json` artifact:
  `verdict` / `report` / `ratings`), `Harness.Audit` + `Harness.Audit.Worker`
  (post-merge third-family audit agent on the global `:audit` Oban queue —
  detached worktree of `origin/<target>`, audits the unaudited commit range,
  ff-pushes its `audit(<short-sha>): …` commit; never blocks, never reverts),
  `Harness.Worktree.diff_size_since/2` + `.harness/` exclusion from commits and
  diff measurement, and `check_command` on `%Harness.Project{}` (a free-text
  hint handed to the reviewer — harness never executes it). Fix-and-approve is
  the reviewer's near-absolute default; rejection is reserved for unsalvageable
  work and puts the task back in the queue with the reviewer's report. Spec:
  `docs/agent-gate-workflow.md`. **This rebuild supersedes the reviewer-pair
  entries below (Tasks 161–163):** `review_green`, `:verifying`,
  `max_review_iterations`, and the check-stack vocabulary they describe no
  longer exist.
- **Shared helper modules from the whole-codebase `/simplify` pass (hand-built
  inline).** `Harness.LineBuffer` (the newline-buffer lifecycle previously
  copy-pasted across the five transcript parsers + the chat stream parser),
  `Harness.JSONSafe` (JSON-coercion previously duplicated in the MCP server and
  chat session), and `Harness.TermCodec` (safe `binary_to_term` previously
  duplicated in the Postgres result store and registry persistence). All six
  parsers, both JSON callers, and both decode callers now delegate; public APIs
  unchanged. One deliberate encoding fix rides along: chat tool results now
  encode `nil`/`true`/`false` as JSON primitives instead of the strings
  `"nil"`/`"true"`/`"false"` (the old `to_jsonable/1` preserve clause was dead
  code, shadowed by its atom clause).
- **Config-driven HIGH-tier grader pairing.** `Harness.AuditReview.default_grader/1`
  reads `config :harness, :audit_review, grader_pairs: %{...}` (documented in
  `config/config.exs`), falling back to the built-in `%{claude: :codex,
  codex: :claude}` when unset — re-pair or extend to new implementers without a
  code change.

- **Deterministic full-pipeline E2E test (Task 173, hand-built inline).**
  `test/harness/pipeline_e2e_test.exs` crosses every seam the pairwise suites
  (run_test, oban_dispatch_test, lander_test, run_landing_trigger_test) only
  test in isolation, in one assertion chain: roadmap task → Oban dispatch
  (`Run.Worker.perform`) → Run gen_statem in a real worktree → agent commit →
  check-stack verdict → landing job → `Lander.Worker.perform` → ff-push to a
  bare `origin/<target>` → rmap writeback (`done` + `verified` + `shipped_in`
  == the landed SHA). Two paths: green (FakeAdapter `:write` deliverable) and
  red→reviewing→green (a `:repair_noop` implementer grades red, the
  cross-family reviewer double fixes the worktree inline, mechanical
  re-verification grades green, and the *reviewed* tree lands). No Postgres
  and no real agent CLIs — Oban interaction is seam-captured and the agent is
  `Harness.FakeAdapter` — but the git repos, worktrees, check execution, and
  rmap ingestion/writeback are all real. Runs in the default suite (not
  `:integration`), no `Process.sleep`.
- **`Harness.GitFixture.init_with_origin/1`** — shared bare-origin + working
  clone fixture (extracted from the hand-rolled copies in `lander_test.exs`
  and `lander/worker_test.exs`), so ff-pushes to `origin/<target>` are real
  and assertable in any suite.
- **Verification-only `inject` step on `Harness.CheckStack` — the Mode-B
  hidden-grader mechanism for the agent-evaluation corpus (Task 151, claude
  delivery + salvage).** Settles the load-bearing decision in
  `docs/agent-corpus-grading.md`: `CheckStack`'s existing `setup` runs in *both*
  `Harness.Verification.prepare/2` (pre-agent, into the worktree) and `run/2`,
  so a grader injected via `setup` would leak into the agent's worktree and
  reveal the API. The new `inject` field runs **only** in `run/2` (after
  `setup`, before the grading `checks`), **never** in `prepare/2` — so a
  withheld grading test can be copied in from a host-side answer key at
  verification time, after the agent has finished, and the agent is graded on a
  behavioral spec it provably never saw. An `inject` failure is an environment
  error (`{:inject_failed, _}`), not a red verdict, mirroring `setup`'s
  `{:setup_failed, _}`. Proven deterministically (no live agent) in
  `verification_test.exs` (`run/2` inject isolation) and
  `corpus_grading_test.exs` (a corpus-shaped repo grading one Mode-A
  visible-spec task and one Mode-B hidden-grader task end-to-end, including a
  hallucinated solution that fails the hidden behavioral grader). Resolves
  concept-doc Q1 (inject), Q2 (host answer key), Q3
  (`CapabilityScore.corpus_version/1` fingerprint), Q4 (vendor the unfamiliar
  lib). The corpus repo itself and the live cross-adapter scoring run are the
  remaining host-side work on Task 151.
- **`Harness.Worktree.Reaper` — same-BEAM crash reaper (Task 185, hand-built).**
  A run that crashes before settle never reaches `Worktree.finish/3`, and the
  `cleanup_for_run/2` liveness guard (Task 180) correctly refuses to touch a live
  run's checkout — so a crash of a refused-cleanup run would leak its worktree +
  `harness/<run-id>` branch until the next boot `Harness.Worktree.Sweeper` pass.
  The reaper monitors each run (`Harness.Run` tracks at worktree-activate, untracks
  at settle) and, on an **abnormal** `:DOWN`, runs the Sweeper's reap — keeping
  `retained?` (settled-`:failed`, kept-for-salvage) worktrees, reclaiming only true
  crash orphans. Closes the within-node gap the boot Sweeper only covers across
  restarts; gated by `:worktree, :reap_on_crash` (off in test).

### Fixed

- **`Audit.select_auditor/1` exclusion normalized to strings (atom-arg
  footgun).** The cross-family exclusion was `to_string(agent) in excluded`,
  but `excluded` was whatever the caller passed: the real Oban-worker path
  passes JSON string args (`"codex"`/`"cursor"`) and excluded correctly, while
  any atom-keyed caller (the `@doc false` unit surface, future in-process
  callers) silently no-matched the `in` test and could pick the reviewer's own
  family to audit its own land. Both sides are now `to_string/1`-normalized;
  regression test asserts atom and string args agree and never select the
  implementer/reviewer family.
- **Reviewer verdict-artifact write made the unconditional FINAL step + reviewing-phase
  idle floor (Task 181, hand-built).** A cross-family reviewer could finish reviewing and
  committing fixes yet exit/idle without writing `.harness/review.json`, losing the run to
  `:review_stuck` despite real work (observed: Pi committed 274 lines, then idle-timed-out
  at ~15.8 min). Per agent-gate doctrine the fix is in the reviewer PROMPT, not a code
  classifier inferring a verdict: `reviewer_prompt/1` now frames the artifact write as the
  mandatory, unconditional last action (exiting without it discards the entire run). Plus
  `reviewer_idle_timeout/1` floors the reviewing-phase idle window at 10 min
  (`@reviewer_idle_floor`) so a silent cold `check_command` run (`cargo test` /
  `mix precommit.full`) can't idle-kill the reviewer before the verdict is written —
  `nil`→floor, lower override→raised, higher override and `:infinity` preserved.
- **Crash-only dispatch: a settled `:failed` run can never trigger a retry storm
  (Task 180, hand-built).** `Harness.Run.Worker` *monitors* — never *links* — the
  run gen_statem, which drives its agents in `async_nolink` tasks, so a settling
  run's agent teardown (`OSProcess.kill/1` + `Port.close/1`) cannot propagate a
  `:killed` EXIT into the worker: a settled `:failed` → `{:cancel}` and a pre-settle
  crash → `{:run_crashed}` → `{:cancel}`, both terminal. `max_attempts` is lowered
  from 20 to `@max_dispatch_attempts` (= `@max_mechanical_attempts`, 5) so a genuine
  uncaught worker crash can't re-run a multi-hour agent run at the old ceiling
  (snoozes self-increment `max_attempts`, so the setup-retry path is unaffected).
- **Per-job orphan rescue (5d1d691 audit follow-up).** `Harness.Oban.rescue_orphaned_run_jobs/0`
  now rescues each `executing` `Run.Worker` job whose `run_id` is **not** in the
  live registry, instead of refusing the whole rescue when any one run is live —
  a live run no longer blocks recovering unrelated orphaned jobs from a prior
  crashed boot.

### Changed

- **Post-merge auditor requires reviewer-eligibility (extends Task 182).**
  `Harness.Audit.select_auditor/1` now consults `AgentSettings.reviewer_eligible?/1`
  in addition to registry availability — the auditor commits and ff-pushes to the shared
  target branch unsupervised, so it demands the same trust flag as the reviewer and lander
  resolver. Promoted to `@doc false` public function for unit testing.
- **Oban job retention extended to 24h.** `Oban.Plugins.Pruner` `max_age` bumped from the
  60s default to 24 hours so settled land/audit jobs remain inspectable in Oban Web.
- **Antigravity worktree isolation (Task 187, superseded by Task 198).** Declared
  `worktree_isolation: true` and lifted pre-spawn rejection; Task 198 corrected the
  isolation mechanism to `--add-dir` (port cwd alone was insufficient).
- **Run lifecycle re-keyed to the reviewer gate (agent-gate rebuild).** States:
  `dispatched → running → committing → reviewing → done|failed` (`:verifying`
  deleted). Reasons: `:approved` / `{:review_rejected, report}` /
  `{:review_stuck, report}` (replacing `:passed` / `:verification_red` /
  `{:verification_failed, _}` / `{:verifier_crashed, _}`). `%Run.Result{}`
  carries `review` (the parsed artifact) + `reviewer_diff_size` (0 =
  first-attempt pass). run_records store verdict `"approve"`/`"reject"` plus
  `review_report` / `review_ratings` / `reviewer_diff_size` (new migration);
  AgentKPI / CapabilityScore re-keyed to reviewer outcomes (success = approved;
  first-attempt pass = approved with zero reviewer fixes; the ratings block is
  the implementer quality signal). Dispatch surface: `Dispatch.task/4` +
  `await/5` (the `review_green` param is gone — review is always mandatory);
  `dispatch__verdict_detail` returns the reviewer's verdict / report / ratings.
  Lander: detached worktree, **no re-verification**, enqueues the post-merge
  audit job after a successful push.
- **Cleanup pass from the whole-codebase `/simplify` review (hand-built inline).**
  `Harness.Dispatch`: the four near-identical enqueue/start clauses collapse to
  one `resolve_and_ingest/3` pipeline, and the `scrub_anthropic_key` /
  `review_green` booleans thread as a single toggles value (MCP surface
  unchanged). `Harness.AgentAdapter.Driver`: distinct `@default_progress_timeout`
  (was silently reusing the idle default) and one config read per run.
  `Harness.Run.Reflex`: deadline wait computed without per-message list
  allocations; worktree path expanded once per blocked-command sweep.
  `Harness.Verification` delegates port helpers to `OSProcess`; `Harness.Roadmap`
  mark_* writebacks share one `landing_ctx/1`; `Harness.Batch` drops the
  reversed-argument `dispatch/2` overload (no callers).
- **Static-analysis pass from `mix reach.check` (hand-built inline).**
  `.reach.exs` rewritten to the actual architecture (the bootstrap policy
  referenced `Harness.Adapters.*` / `Harness.Surface.*`, namespaces that never
  existed): dashboard ↮ adapters invariants as forbidden-call rules + the
  descripex driver surface as public facades; `mix reach.check --arch` is green
  and CI-usable. Smell fixes ride along: `ChatLive.normalize_snapshot/1` builds
  prepend-and-reverse instead of `++`-appending per message (and
  `merge_one_result/3` drops its double-reverse), `Map.keys |> Enum.each` →
  pair iteration (CompareLive), `case` → `match?/2` (Worktree),
  guard-on-literal → pattern-matched clauses + deduped `Path.expand`
  (ConfigInspector), `map |> flat_map` → single `flat_map` (Chat.Store,
  ResultStore.File), redundant `map_join` separator (ChatLive), and a
  pattern-level discard replacing `_ = old` (RunDiff).

- **Clone elimination from `mix ex_dna` (hand-built inline) — 10 clones → 0
  across 118 files.** `Harness.Dashboard.Transcript.Parser` is now a behaviour
  (`@callback new/0`, `feed/2`, `finalize/1`) with a `use` macro that generates
  all three over a new `Harness.LineParser` (the shared NDJSON
  line-buffer + `Jason.decode` loop); the five NDJSON parsers shed their
  per-module boilerplate and the Claude↔Cursor block translators move to shared
  `Parser.translate_assistant_block/1` / `translate_user_block/1` (Task 178).
  `Harness.Chat.Claude.StreamParser` stays a separate domain (bare-string vocab)
  but also routes through `LineParser`. The `.tmp`+rename term-file plumbing —
  previously copy-pasted in six stores — collapses to
  `Harness.TermCodec.read_file/1` + `write_file/2` (Agent/Cron/Landing settings,
  Chat.Store, ResultStore.File, the import-results task), retiring the
  `TODO(Task 165)` rule-of-three marker (165 still owns the Postgres-backed
  consolidation). Three 2-site clones lifted to shared homes:
  `Harness.Project.local_repo_path/1` (Audit + Lander),
  `Harness.Oban.put_env_arg/2` (Batch + Run.Worker), and
  `Harness.ResultStore.pop_limit/1` (File + Postgres backends).

- **`Harness.Lander.Worker` now applies the runtime landing override
  (`Harness.Landing.Settings.overlay/1`) to the project it resolves from the
  registry (Task 171).** `Harness.Run` already applied the overlay at init, so
  green settles on dashboard-flipped projects enqueued landing jobs — but the
  worker re-resolved the raw registration (`landing_policy: :manual`, no
  `target_branch`), so every such landing job failed `{:error,
  :no_target_branch}` → 3 Oban retries → discarded. Projects whose auto-land is
  flipped on from the dashboard (rather than at registration) can now actually
  land. Regression + control tests in `test/harness/lander/worker_test.exs`.

### Removed

- **Harness.TermCodec + legacy *.term import window closed (Task 213 capstone).**
  Deleted `lib/harness/term_codec.ex`, `lib/harness/legacy_term_import.ex`,
  `lib/mix/tasks/harness.import_results.ex` and tests (~810 LOC). Removed the
  `LegacyTermImport` Application child, all `import_legacy` paths, and the
  one-time cutover tooling now that ResultStore/Chat/Audit/Settings/ProjectRegistry
  are Postgres-only (or ephemeral) with no remaining `*.term` readers. Inlined
  minimal owned-payload `decode_term/1` (sobelow_skip) at the three internal
  call sites. Test/config cleanups removed legacy_root plumbing. The 212
  retirement bullet documented the cutover provision; this closes the window.
- **The mechanical verification stack — deleted whole (agent-gate rebuild).**
  `Harness.Verification` (+ check/result/verdict modules),
  `Harness.CheckStack` (+ Elixir/Rust presets), the `:verifying` run state,
  `review_green`, `max_review_iterations`, lander re-verification +
  `{:post_merge_red, _}`, the mechanical benchmark corpus
  (`Harness.Benchmark.*`, `priv/benchmarks/`,
  `Harness.Cron.CapabilityBenchmarkScheduler`), and the docs that specified
  them (`docs/agent-corpus-grading.md`, `docs/reviewer-pair-architecture.md` —
  replaced by `docs/agent-gate-workflow.md`).
- **Reviewer-pair lifecycle, step 3 — the deletion pass: judgment code is gone,
  the reviewer pair is the only path (Task 163, hand-built inline).** Every
  mechanism that interpreted *meaning* in procedural code is deleted; the
  cross-family reviewer (Tasks 161/162) absorbs the judgment. Net
  **−1,219 lines** in `lib/` + `config/` (+470/−1,689 across 32 files);
  **−1,702** for the whole pass including test rewrites (+959/−2,661, 66 files).
  - **Whole modules deleted:** `Harness.Run.FailureClass` (131 lines — regex
    failure classification), `Harness.Run.RepairPrompt` (100 — repair-prompt
    formatting), `Harness.Verification.BaselineFilter.Credo` (273 —
    finding-level baseline attribution).
  - **Repair loop** (`repair_attempts`, `max_repair_attempts`,
    `repair_prompt_kind`, `last_failed_check_signatures`, the verifying→running
    loopback), the **`:consulting` state + cross-agent-repair machinery**, the
    **semantic gate**, and the **quota regexes** deleted from the `Run`
    gen_statem (`run.ex` −545/+93). Operator steer survives as the only resumed
    invocation; its composed-input phase is renamed `:repair` → `:steer`.
  - **Baseline verification** (`run_baseline_stacks`, `mark_pre_existing`,
    `:persistent_term` cache, `:base_red`, `post_process` check plumbing)
    deleted from `Harness.Verification` (−173/+28); verdicts are pass/fail only.
    Inherited debt is no longer attributed away — the reviewer pays it down
    (regression scenarios rewritten against the reviewer path).
  - **`RetryPolicy` rewritten to backoff arithmetic only** (−136/+18):
    `new/1` + `backoff_ms/2`, no `quota_patterns`, no `decide`, no run wrapping.
    `Batch` no longer retries at all.
  - **The `repair_attempts` metric is renamed `review_iterations`** across
    `Result` / `Status` / `LogRecord` / KPI stack / capability scores /
    dashboards ("how much extra help did this run need", now fed by the
    reviewer).

### Changed

- **Oban dispatch goes crash-only (Task 163).** Any settled failure — including
  `worktree_failed` and `agent_spawn_failed` — cancels the job
  (`{:cancel, reason}`) and reverts the roadmap task to pending; a settled
  verdict is never re-run by the queue. Only pre-settle mechanical setup
  failures snooze, capped at 5 attempts
  (`{:cancel, {:mechanical_retry_exhausted, reason}}`), and each mechanical
  retry first runs `Worktree.cleanup_for_run/2` to remove the prior attempt's
  leftover worktree + `harness/<run_id>` branch (the branch-collision bug,
  absorbs Task 168).
- **Batch failover is reviewer-judgment-based (Task 163).** An adapter is marked
  unavailable when a run settles `{:review_stuck, _}` with an empty implementer
  diff — the reviewer's prose stuck-report rides in the
  `AgentRegistry.mark_unavailable/2` mark and the `:adapter_unavailable` /
  `:failover` batch events. No more quota-regex classification.
- **`ResultStore.Postgres.record_run/2` upsert never loses settled evidence
  (Task 163).** Re-recording a `run_id` COALESCEs rich evidence columns
  (verdict, outputs, reviewer fields; `review_iterations` takes GREATEST) so a
  sparse later write only updates bookkeeping. New migration adds
  `review_iterations` / `reviewer_adapter` / `reviewer_stuck_report` columns
  (run `mix ecto.migrate`).

### Added

- **Reviewer-pair lifecycle, step 2 — empty-diff and green verdicts route through
  the reviewer; `semantic_gate` → `review_green` (Task 162, hand-built inline).**
  An empty implementer diff is no longer judged by procedural code (the
  `:no_changes` disposition is unreachable from the run lifecycle): every run
  verifies, and what an empty diff *means* — already implemented vs nothing
  happened (e.g. quota exhaustion) — is the cross-family reviewer's call, framed
  by a scope-specific prompt (`:fix_red` / `:empty_diff` / `:green_conformance`).
  Green verdicts route through `route_green_verdict/1`: a project with
  `review_green: true` (the **default** — no unreviewed code lands) or a run with
  an empty implementer diff gets **exactly one** reviewer conformance pass; the
  check stack re-runs after the reviewer, and a wanted-but-unavailable reviewer
  fails OPEN to `:done` (green is ground truth — Task 158's lesson). The
  `Project.semantic_gate` mode enum (`:always` / `:auto_land_only` / `:off`) is
  **replaced by `review_green: boolean`**; legacy configs and persisted
  `term_to_binary` payloads are mapped at registry load (`:always` /
  `:auto_land_only` ⇒ `true`, `:off` ⇒ `false`, absent ⇒ `true`). The
  per-dispatch MCP/chat override param is renamed `semantic_gate` →
  `review_green` on `dispatch__task` / `dispatch__await`; `Run.Worker` job args
  carry `"review_green"`. The reject-into-repair-loop semantic gate
  (`:consulting` on green) no longer fires — its machinery is deleted wholesale
  in Task 163.

- **Reviewer-pair lifecycle, step 1 — `:reviewing` state: a cross-family reviewer
  agent fixes red worktrees inline (Task 161, codex delivery + reviewer salvage).**
  A red verdict now routes through `route_red_verdict/1` to a new `:reviewing`
  gen_statem state instead of the repair loop: a **cross-family reviewer adapter**
  (different agent family than the implementer; `select_reviewer/1` auto-picks,
  explicit `reviewer:` opt overrides) gets a fresh session in the SAME worktree
  with the task spec, implementer transcript tail, diff stat, and full
  failing-check output, and fixes inline — its own edits and commits. After each
  reviewer session harness **re-runs the check stack mechanically**; the
  reviewer's word is never the verdict. One mechanical knob:
  `max_review_iterations` (default 2; `0` settles `:failed` immediately — the
  test-env default via `config :harness, :run`). Iterations exhausted or no
  cross-family adapter available settles `:failed` with the reviewer's
  stuck-report as prose reason. `Run.Result` / `LogRecord` / `Run.Status` carry
  `reviewer_adapter`, `review_iterations`, `reviewer_stuck_report`; `StatusView` /
  `CompareLive` bucket `:reviewing` as repairing. The now-unreachable repair-loop
  routing functions are deleted; deprecated quota-pattern and cross-agent-repair
  tests are removed (their behavior is disabled by the `quota_patterns: []`
  interim config and is deleted wholesale in Task 163).

- **Cron schedule editing from the dashboard — boot-applied presets (Task 111).**
  `Harness.Cron.Settings` now persists the poll cadence alongside the 109/110
  autonomy switches (same `:cron_polling` config + term file), so
  `RoadmapPoller.schedule/0` / `cron_plugin/0` source it at boot, falling back to
  `@default_schedule` (`0 */2 * * *`) when unset. `SettingsLive` gained a preset
  picker (hourly / 2h / 6h / daily) backed by a closed `schedule_presets/0`
  whitelist — `set_schedule/2` rejects any non-preset key
  (`{:error, :invalid_preset}`), so a free-form crontab can never reach Oban. The
  schedule is **boot-applied** (the Cron plugin's crontab is built once at
  startup); a change takes effect on the next restart, and live runtime reconfig
  is deliberately out of scope. Current schedule + next tick already render via
  `RoadmapPoller.status/0`. `load_into_env/0` applies a persisted schedule only
  if still whitelisted (back-compat for records written before Task 111).

- **Verification baseline attribution — inherited red is no longer blamed on the
  agent (Task 153, codex delivery).** When a check fails, `Harness.Verification`
  now re-runs the same check stack against the dispatch base (`:base_ref`, the
  worktree's `base_sha`) in a throwaway detached worktree, cached per base SHA
  via `:persistent_term`. Checks that also fail on the unmodified base are
  marked `:pre_existing`; a run whose only failures are pre-existing settles
  with verdict/reason `:base_red` instead of `:fail` / `:verification_red` —
  never silently green, never agent-blamed — and the repair loop is not
  triggered for it. Generalizes the credo `BaselineFilter` precedent from
  finding-level to whole-check attribution.

- **Cron dispatch scrubs subscription-agent provider API keys (Task 154).**
  `Harness.Cron.RoadmapPoller` now persists per-agent env scrubs into
  `Run.Worker` job args for subscription-operated Claude and Codex dispatches
  (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`), while leaving Cursor/Grok/
  Antigravity/Pi args unchanged. Operators can override
  `:cron_polling, :subscription_env_scrubs` to intentionally run an agent on its
  inherited metered API key.

- **Runtime ProjectRegistry registrations persist to Postgres (Task 141, cursor
  delivery).** `Harness.ProjectRegistry.Persistence` upserts/deletes runtime
  `register/1` / `unregister/1` calls in a new `projects` table (name PK,
  `term_to_binary` payload); the registry restores persisted projects at boot —
  config-declared projects win on name conflict — so runtime registrations now
  survive a BEAM restart. Guarded by `:repo_enabled` with rescue/log
  degradation (registry stays functional without Postgres);
  `Harness.ProjectRegistry` moved after `repo()` in the supervision tree so the
  restore can read the database.

- **Per-project landing policy from the dashboard — Landing card +
  `Harness.Landing.Settings`.** The Settings page gains a Landing card: a
  per-project `manual` / `auto-land` select + target-branch input, persisted
  across restarts via a file-backed term store
  (`~/.harness/landing_settings.term`) that overlays the registration-time
  `landing_policy` / `target_branch` when a run initializes — arming auto-merge
  no longer requires hand-editing the registry via `iex`. Auto-land without a
  target branch is rejected (`{:error, :target_branch_required}`); `:manual`
  clears the branch. Also adds a **Dispatch now** button that enqueues an
  immediate roadmap poll (honoring the master kill-switch) instead of waiting
  for the next cron tick, with transient ok/error feedback via a `:notice`
  assign.

- **Autonomous dispatch routes on rmap's `assignee` field (Task 130, codex
  delivery).** `RoadmapPoller.task_agent/1` now routes on `assignee` — rmap's
  validated agent-routing field (../rmap task 40) — instead of overloading the
  free-text `model` LLM pin and the `cx`/`csr` markers. `assignee = "human"`
  tasks are skipped by autonomous dispatch (`:human_assigned`); missing
  assignees and assignees with no harness adapter (e.g. `droid`) fall back to
  `:claude`. `Roadmap.ready/1` and the `roadmap__ready` MCP docstring request
  `--fields id,assignee,markers`; the harness roadmap's agent-name `model`
  values migrated to `assignee`; `skills/harness-driver/SKILL.md` updated.

- **Postgres codec unit tests via fake repo.** The `LogRecord` ↔ row codec
  (tuple `agent_outcome_kind`, `$atom`/`$tuple`/`$list` jsonb markers,
  `TokenUsage` struct restore, never-raise contract) is now graded by the
  default suite through an injected in-process repo — the regression net for
  the `{:timed_out, :idle}` crash class, previously only covered by
  `:integration`-tagged tests the verification stack never runs. Also lifts
  project coverage back over the 80% gate (79.83% → 81.97%).

- **Autonomous capability-benchmark cron scheduler (Task 122, cursor delivery).**
  `Harness.Cron.CapabilityBenchmarkScheduler` closes the capability-trust loop:
  an Oban cron worker (default `0 3 * * *`, behind
  `config :harness, :cron_capability_benchmark` — `enabled: false` by default)
  selects the (agent, domain) cells `CapabilityScore.rebenchmark_candidates/1`
  flags as unmeasured or stale, prioritizes unmeasured > stale, caps cells per
  tick (`max_cells_per_tick`, truncations logged as deferred — never silently
  dropped), skips unavailable agents via `AgentRegistry`, runs the matching
  benchmark corpus items through `Batch.AgentEvaluation.compare/4`, and persists
  scores via `CapabilityScore.score_domain/4`. Fresh cells are never re-run.
  `Harness.Benchmark.as_roadmap_item/2` bridges corpus items to dispatchable
  roadmap items; `Harness.Oban` now composes the RoadmapPoller and scheduler
  cron entries into a single `Oban.Plugins.Cron` plugin. `status/0` /
  `next_tick/1` mirror the RoadmapPoller observability surface.

- **Run recovery — hold/steer/resume gen_statem API (Task 150, cursor delivery).**
  Operator-mediated mid-run recovery: `Harness.Run.hold/1` parks a struggling run
  in a new `:held` state at the next settle boundary (`hold(run, interrupt: true)`
  kills the agent and parks immediately); `steer/2` stashes operator feedback
  (append-accumulating); `resume/1` re-enters `:running` via the existing
  repair-resume path (`session: :resume` into the same worktree) carrying the
  operator prompt as `repair_prompt_kind: :operator_steer`. The lifetime timer is
  suspended while held and re-armed on resume; a `max_hold_timeout` safeguard
  (default 30 min, `:infinity` disables) settles `:failed` with reason
  `:hold_expired` so a forgotten hold can't leak a worktree. `steer/2` on a
  `session_resume: false` adapter (antigravity) returns
  `{:error, :resume_unsupported}`. `Run.Status` gains `held?`/`hold_reason`;
  `StatusView` classifies `:held` as in-flight. Backend half of
  docs/run-recovery-design.md; the dashboard Hold/Steer/Resume UI is a separate
  hand-built follow-on.

- **Capability score staleness/decay + recommend-agent routing (Tasks 120 + 121,
  codex delivery, one combined run).** Task 120: `CapabilityScore.freshness/2`
  classifies each persisted (agent, domain) score as fresh/stale against a
  configurable window (default 30 days, injectable `reference_time` for
  determinism); `discounted_composite_score/2` applies a stale discount (default
  0.5); `rebenchmark_candidates/1,2` lists stale + unmeasured cells as
  re-benchmark candidates — stale scores are flagged, never deleted. Task 121:
  `CapabilityScore.recommend/2` explore/exploit routing — an unmeasured
  (agent, domain) cell is an exploration candidate (not a low score), measured
  cells exploit the best discounted score, and a no-data domain falls back
  (default `:claude`, configurable). Surfaced as `Harness.Dispatch.recommend/2`
  + MCP tool `dispatch__recommend`, and wired into the dispatch path:
  `dispatch__task`/`dispatch__await`'s default adapter changed from `"claude"`
  to `"recommend"` so the orchestrator consults scores at the decision point
  (explicit adapter names bypass routing). New
  `ResultStore.list_capability_scores` callback on both File and Postgres
  backends; `Roadmap.ingest` now threads task `domains` tags onto the Item.

- **A/B agent-evaluation dashboard view (Task 81, `Harness.Dashboard.CompareLive`).**
  New LiveView at `/harness/compare` (launch form) and `/harness/compare/:comparison_id`
  (the grid) surfacing `Harness.Batch.AgentEvaluation.compare/4` side by side: one
  full-bleed CSS-grid lane per adapter, the verdict cell dominant and pass/fail
  deliberately asymmetric, with per-adapter metric rows (verdict, repair attempts,
  duration, first-pass red checks, diff size, tokens). Click a lane header to switch
  the lower transcript pane to that adapter (`JS.patch` with a `?tab=` param, so the
  pane is shareable). The synchronous `compare/4` runs in a spawned process and the
  lanes fill live from `RunFeed`, correlated by `(task_id, agent)` since `Run.Status`
  carries no `batch_id`; a reload reconstructs settled lanes from `ResultStore` run
  records. Reuses `Tokens` + `page_shell/1` + the Task-87 `transcript_view/1`; a new
  `.compare-*` token block carries the layout. Per-adapter transcripts are bounded
  assigns lists (the Task-87 `transcript_view` groups a full event list, which a
  per-event `stream/3` can't express — the MB-scale concern the `stream/3` AC guarded
  against is already met by the 500-event `Transcript` cap).

- **Capability scoring + persistence per (agent, domain) (Task 119, codex
  delivery).** `Harness.CapabilityScore` turns the per-adapter metrics
  `Batch.AgentEvaluation` already produces into a persisted composite score —
  success-rate-dominant, cost-to-green as tiebreaker — keyed by
  `(agent, domain, corpus_version)` with `scored_at`. Raw per-run metrics are
  retained alongside the composite so it can be retuned without re-running the
  benchmark; an unmeasured cell reads `:no_data`, distinct from measured-low.
  Persisted via new `ResultStore` callbacks (`save_capability_score` /
  `get_capability_score`) on both the File and Postgres backends
  (`capability_scores` table). Feeds Tasks 120 (staleness) and 121 (routing).

- **Dashboard/KPI SQL fast paths + file-store importer (Tasks 139 + 138, cursor
  delivery, one combined run).** The KPI ledger and run history previously
  loaded *every* persisted run record — transcripts included — into memory to
  compute scalar aggregates:
  - `ResultStore.aggregate_by_agent/1` — new behaviour callback; Postgres issues
    one `GROUP BY agent` aggregate query, the File backend falls back to
    `AgentKPI.aggregate/1`. KPILive renders identical numbers on both (golden
    parity test).
  - `list_run_records` gains `:limit` and orders by `inserted_at DESC`; list
    queries omit the `agent_output` bytea (only `run_id:` point lookups load
    transcripts). `StatusView` history drops the run-id string-sort recency hack.
  - `mix harness.import_results` — one-shot, idempotent file-store → Postgres
    importer (`--root` / `--repo` flags, tolerant decode, imported/skipped
    summary) for operators who want pre-cutover history.
  - Landing fix: `run_records` timestamps are now microsecond-precision
    (migration `20260602010000`) — at second precision, `inserted_at DESC`
    ordering was non-deterministic for runs recorded within the same second.

- **Parameterized `:rust` preset (Task 149, grok delivery).**
  `Preset.fetch(:rust, opts)` / `Preset.Rust.preset/1` accept `:target_dir`
  (threads `--target-dir` into clippy/test/build, omitted on fmt), `:release`
  (`false` ⇒ plain `cargo build`), `:timeout_per_check`, and `:env` (stamped
  onto every check via the `Check.env` field from Task 145). A heavy Rust
  project like rexex — shared cargo target dir, no redundant release build,
  `DATABASE_URL` for sqlx tests — is now expressible durably in config as
  `preset: {:rust, opts}` instead of a runtime-only registration hack.

- **Worktree provisioning — check-stack setup runs before the agent spawns
  (Task 147).** A freshly carved worktree had no `deps/` or `_build/`, so the
  dispatched agent's first `mix` command silently fetched and compiled every
  dep for minutes — long enough to trip the driver's idle/progress reflex and
  kill the run (observed on grok dispatches). The run now warms the worktree
  between worktree creation and agent spawn:
  - New `Harness.Verification.prepare/2` runs every resolved stack's `setup`
    commands (no grading checks) with `run/2`'s option and error vocabulary.
  - `Harness.Run`'s `:dispatched` state provisions after `Worktree.activate` +
    `Isolation.validate`; the agent only spawns into a warmed worktree. A
    provision failure settles the run `:failed` with
    `{:worktree_failed, {:setup_failed, _}}` — an environment error, never a
    red verdict — and the agent never spawns.
  - The Elixir presets (`preset/0`, `precommit/1`) declare a second setup step
    `mix deps.compile`, so the expensive dep compile happens at provision time
    and verification's own setup pass is a fast no-op.

- **Project attribution, roadmap rollup, and a task-level merge signal on the
  dashboard index.** The run tables showed task/run/agent but not *which project*
  a run belonged to, and the index gave no view of how much roadmap was left or
  whether settled runs ever landed. Three additions close that:
  - **Project column** on the active + history run tables (`status.project_name`).
  - **Roadmap panel** — per registered project, the open / done / total task
    counts plus how many tasks the lander has landed. Backed by a new pure
    `Harness.Dashboard.RoadmapSummary` (one `rmap list` per project, refreshed on
    a slow 30s `:roadmap_tick`; a `:roadmap_list` test seam mirrors the poller's
    `:roadmap_ready`). A project whose roadmap can't be read contributes a zero
    summary rather than crashing the panel.
  - **Landed column + unmerged-by-default history.** "Merged" is a property of
    the *task* (its `shipped_in`, written by the merge-train lander or a human
    salvaging the code) — **not** the run's terminal state, so a `:failed` run
    whose code is later salvaged and landed correctly reads merged. History now
    defaults to the actionable **unmerged** set (every open loop regardless of
    red/green), with a toggle (carrying the hidden-landed count) to reveal landed
    runs; the `Landed ✓<sha>` column shows the join. The slow tick re-streams
    history so a run drops out the moment its task lands.

- **Read-only configuration inspector on the operator settings page (Task 127).**
  A long-running harness node had no way to *see* how it was configured without
  shell access to read `config/config.exs` + `config/runtime.exs` and mentally
  resolve env-var overrides. `/harness/settings` now renders a "Configuration"
  card surfacing the resolved *effective* config grouped by concern — dashboard,
  run timeouts, verification, cron polling, repair/gating, notifications, result
  store, paths, worktree, retry policy, database — plus a registered-projects
  sub-section (source / roadmap / concurrency cap / check-stack + workdir).
  - New `Harness.Dashboard.ConfigInspector.resolve/0` (pure, declarative spec)
    reads each concern's app env and tags every row with a **provenance** pill:
    `default` / `config.exs` / `env: HARNESS_…`. Provenance is a documented
    heuristic — at runtime a compile default and a `config.exs` override are
    indistinguishable, so it keys on env-var presence first, then value-vs-default.
  - **Secrets never render**: `secret_key_base` shows `[redacted]`; the database
    section surfaces only `database` / `username` / `hostname`, never the password
    or a connection URL.
  - Rendered by a new pure `Harness.Dashboard.Components.config_inspector/1`
    component (sibling card on the existing cron/agent `SettingsLive` page; the
    nav link already existed). Read-only by design — runtime-mutable controls
    (cron autonomy, agent rotation) keep their own toggles on the same page.
  - **Made the inspector actionable** (post-review polish): every env-overridable
    row now shows the **knob** — the `HARNESS_…` env var that changes it — even
    when the key is at its default, so the operator always knows *how* to change a
    value despite the page being read-only. Millisecond durations render humanized
    (`30 min (1800000 ms)`), and a legend + read-only banner explain the
    provenance vocabulary and point at the live toggles above. Closes the "shows
    `default` but I can't set anything / doesn't explain what default is" gap.

- **Agent and model now visible on both the run dashboard and run-detail page.**
  Neither surface previously showed *which agent* (let alone which model) ran a
  given run — the run-detail header surfaced `Status.agent_kind`, which is the
  *outcome* kind (`:exited` / `:timed_out`), not the agent identity, and the
  index run tables had no agent column at all.
  - `Harness.Run.Status` gains an `agent` (identity atom, resolved at run start
    from the gen_statem's `data.agent_kind`) and a `model` field, distinct from
    the misnamed `agent_kind` (outcome kind, left as-is for compatibility).
  - `Harness.Run.LogRecord` gains a `model` field, parsed once at settle from the
    agent's transcript by the new `Harness.AgentModel.parse/2` (claude / cursor
    self-report the model — `claude-opus-4-8`, `Composer 2.5 Fast`; codex / grok /
    antigravity emit no model field, verified against captured transcripts, so
    they render "—"). The *requested* model (rmap task `model`) is a separate fact
    not present in agent output — capturing it is a possible follow-up.
  - Dashboard index `run_table` adds **Agent** + **Model** columns (live and
    history rows). Run-detail page adds a **Model** row that prefers the stored
    value and falls back to live-parsing the in-flight transcript, so a running
    claude/cursor run shows its model immediately.
  - Pre-change persisted records carry no stored `model`, so the index Model
    column reads "—" for them (no backfill); new runs populate it. The detail
    page still shows their model via the live transcript parse.

### Changed

- **Adapter/agent state consolidated onto Settings.** The `/harness` dashboard no
  longer renders the static **Adapters** table or **Unavailable agents** list — both
  duplicated what the Settings *Agents* card already owns. The dashboard is now purely
  operational (Roadmap / Active runs / Run history); the transient quota/`unavailable`
  signal is folded into the Agents card as a "paused" pill (the card's copy already
  referenced a "transient quota pause"). Drops the `:adapters` / `:unavailable` assigns
  and `list_adapters/0` from `Dashboard.Live`.

### Fixed

- **Empty-diff runs are verified instead of cancelled `:no_changes` (Task 159,
  codex delivery + reviewer salvage).** A run whose agent makes zero edits no
  longer short-circuits to `{:cancel, :no_changes}` before verification: when
  the agent completed normally (`kind: :exited`, no quota exhaustion) and the
  project has meaningful checks, harness grades the current branch state —
  green settles `:done` (the already-implemented case, e.g. rmap task 32 on
  cursor), red settles `:base_red`, and only a genuinely ungradeable no-op
  still cancels. The reviewer-salvaged gap: quota-exhausted/timed-out/crashed
  no-op agents stay failed (`normal_agent_completion?`), preserving
  quota-failover semantics. First landing reviewed-and-fixed by a cross-family
  agent per the reviewer-pair model (docs/reviewer-pair-architecture.md).

- **Baseline verification runs get the same diff-aware post_process as the agent
  worktree (Task 160, hand-built).** `run_baseline_stacks/4` never passed
  `:base_ref` into the baseline run's post-process opts, so
  `BaselineFilter.Credo` was a no-op on the baseline: any TagTODO tracked-debt
  comment on the base kept baseline credo `:fail`, and agent-introduced credo
  findings of the same check were then masked as `:pre_existing` →
  verdict `:base_red` — the run settled failed with `repair_attempts: 0` and the
  agent never got its own findings fed back. Observed live on both 2026-06-02
  interactive dispatches (runs `…cc989923` / `…69e683e9`). The baseline now
  re-grades by the same standard as the agent worktree, so inherited debt is
  filtered on both sides and agent faults stay `:fail` → repair loop fires.
  Genuinely-red bases (failures no post_process filters) still settle
  `:base_red`.

- **Post-green semantic gate fails open to `:done` when its grader is unavailable
  or disabled (Task 158, codex delivery).** A green verdict used to enter the
  semantic-gate consultation unconditionally when the gate was enabled — if no
  cross-family grader was dispatchable (or the operator disabled the grader), the
  gate rejected the green run and burned repair attempts on work the check stack
  had already passed. `Harness.Run` now routes green verdicts through
  `settle_green_verdict/1`: the gate is consulted only when it is enabled AND
  `semantic_gate_grader_available?/1` — otherwise the run settles `:done`
  directly. Mirrors Task 59's AuditReview availability semantics.

- **Interactive `dispatch-task` runs are now Oban-backed and restart-resilient
  (Task 156, codex delivery).** The MCP/chat fire-and-forget dispatch path now
  pre-generates a run id, persists it in the `Harness.Run.Worker` job args, and
  returns that id only after the Oban row is inserted. The worker reuses the
  stored id when it starts `Harness.Run`, so a BEAM restart can rescue/re-run the
  durable job instead of silently losing the run with no trace.

- **Orphaned `executing` Run.Worker rows are rescued at boot instead of
  zombie-ing forever (Task 157, codex delivery).** A BEAM restart mid-run used
  to strand the run's Oban job row in `executing` — never completing, blocking
  re-dispatch via the poller's unique gate, and pinning the rmap task
  `in_progress`. `Harness.Oban` now runs a boot-time reconcile sweep (a
  temporary Task child, after Oban / before QueueBootstrap) that flips
  `executing` `Harness.Run.Worker` rows back to `available` when no live run
  gen_statem exists, so the persisted job re-runs on the fresh node. The sweep
  is guarded by `Run.Supervisor.list_runs/0` — rows are never touched while any
  run is live — and a rescued row conflicts with (rather than duplicates) a
  re-dispatch of the same task.

- **Autonomous dispatch can now reach every registered agent, not just
  claude/codex/cursor.** Two stale 3-agent gates blocked grok/antigravity/pi end
  to end — surfaced live when an rmap `grok` task routed correctly but its run
  job was cancelled with `{:unsupported_adapter, …}`:
  - `Harness.Cron.RoadmapPoller` carried a hand-maintained `@assignee_agents`
    map covering only those three; a `grok` / `antigravity` / `pi` assignee
    silently fell back to `:claude` — skipped when Claude was disabled, or
    misrouted to a metered agent when enabled. Routing now resolves the
    `assignee` against `Harness.AgentRegistry` (the single source of truth), so a
    new adapter is dispatchable with zero poller edits. An assignee that names no
    harness adapter (e.g. `droid`) resolves to `{:unsupported_assignee, raw}` and
    is logged-and-skipped — never misrouted. A missing assignee still defaults to
    `@default_agent` (`:claude`).
  - `Harness.Run.Worker.agent_for_adapter/1` then re-narrowed the resolved agent
    with a stale `agent in [:claude, :codex, :cursor]` guard, cancelling any
    grok/antigravity/pi run as `{:unsupported_adapter, _}`. It now delegates to
    `AgentRegistry.agent_for_module/1` — any registered adapter is accepted; only
    a loaded module the registry doesn't know is cancelled.
  - `Harness.Roadmap.Item.t`'s `agent` field type (and the `Roadmap.ingest`
    `:agent` doc) listed only the original three despite `ingest` producing all
    six via `@valid_agents`; both now reference the registry's agent set.

- **Stale `Adapters`-on-index assertion broke the default suite (and falsified a
  dispatch verdict).** The dashboard refactor that moved adapter/unavailable
  state into Settings (cebe648) updated `live_test.exs` and
  `settings_live_test.exs` but missed `live_mount_test.exs`, leaving the default
  suite red on `development`. The first dispatch graded against that base
  (task 130, codex) got a false-red verdict for a failure it didn't cause. The
  assertion now matches the post-refactor index.

- **Flaky Task-150 hold/cancel test made deterministic (Task 152, grok
  delivery).** `run_test.exs` "cancel/1 from :held" raced `Run.cancel/1` against
  the graceful hold parking at the next settle boundary — under full-suite load
  the race lost and the test timed out at 60s. The test now subscribes to
  `RunFeed` and `assert_receive`s the `:held` status transition before calling
  `cancel/1`, so it genuinely exercises cancel-from-`:held`. Synchronization
  fix, no sleeps, no timeout bumps.

- **Postgres result store crashed the run gen_statem on tuple outcome kinds
  (`{:timed_out, :idle}`).** `Postgres.log_record_to_attrs/1` serialized
  `agent_outcome_kind` via `atom_or_string/1`, which has no clause for the tuple
  kinds in `Outcome.kind()` (`{:timed_out, _}`, `{:reflex_halted, _}`,
  `{:error, _}`) — so any run whose agent didn't exit cleanly raised a
  `FunctionClauseError` inside `settle/2`, killing the run process and discarding
  whatever was queued behind it (observed: a passing verification verdict). Two
  fixes: a dedicated kind↔string codec (tuples serialize as JSON `$tuple`/`$atom`
  marker text, bare atoms stay plain strings for back-compat with existing rows),
  and `record_run/2`'s rescue now covers serialization, so a future codec gap
  surfaces as `{:error, _}` to the caller's existing warning path instead of
  crashing the gen_statem. Regression coverage added to the shared
  `ResultStoreContract` so both File and Postgres backends roundtrip tuple kinds.

- **Crashed Oban-dispatched runs are now recorded and broadcast (Task 134, codex
  delivery).** When a supervised run process died before reaching its own
  `settle/2`, `Harness.Run.Worker.await_run` synthesized a `:failed` Result for
  Oban but never persisted it nor broadcast it — so a crashed cron/overnight run
  left zero `ResultStore` records and never appeared on the dashboard (the
  "ZERO records overnight" observation). The worker's `:DOWN` branch now routes
  the synthesized Result through the same path the happy path uses
  (`LogRecord.from_result` → `ResultStore.record_run` +
  `Run.Status.from_log_record` → `RunFeed.broadcast_settled`), built from what
  the worker has on hand (run/task/agent/adapter/project + wall-clock duration).
  Closes the backend residual of Task 134; the live-update UI half shipped
  earlier in 8bbbc5e.

- **Grok token usage now recovered from its on-disk session log (KPI showed 0).**
  Grok's headless `--output-format streaming-json` stdout — the stream harness
  captures over the Port — carries no token counts; its terminal `end` event is
  only `stopReason`/`sessionId`/`requestId`. So `Harness.TokenUsage.parse(:grok,
  …)` honestly returned empty and the KPI "Mean tokens" column read `0` for grok
  while cursor/codex showed real figures. Grok *does* record usage, but to a
  session log under `$HOME` (`~/.grok/sessions/<encoded cwd>/<id>/updates.jsonl`,
  cumulative `_meta.totalTokens`), which survives worktree teardown. New
  `Harness.TokenUsage.GrokSession` locates that file by the globally-unique
  `sessionId` (sidestepping the cwd percent-encoding; session id validated to
  the uuid charset so it can't traverse) and recovers the cumulative total.
  - `Harness.Run` accumulates grok usage by **replacing** (not summing) the
    running total with the recovered cumulative figure, since `--continue` repair
    attempts share one session log whose `totalTokens` already spans all attempts.
  - `Harness.TokenUsage.measured?/1` now treats a total-only usage (grok reports
    no input/output split) as measured, so the recovered figure surfaces in both
    the KPI rollup and the run-detail transcript token row.
  - Fix applies to grok runs settling after the change; a pre-fix run's persisted
    record keeps its `nil` total until re-run or backfilled.

- **Cross-agent transcript-rendering inconsistencies on the run dashboard.**
  Comparing live cursor/codex/grok runs surfaced four UX divergences in how the
  same dashboard renders different agents' transcripts:
  - **Cursor tool calls rendered as bare "OTHER" eyebrow rows.** The cursor
    parser assumed Claude's `assistant`/`tool_use` + `user`/`tool_result` block
    shape, but cursor actually emits `{"type":"tool_call","tool_call":{"<kind>ToolCall":{…}}}`
    (started/completed) and `{"type":"thinking","subtype":"delta"}` — all of which
    fell through to `:other`. Added explicit clauses: `tool_call` → `:assistant_tool_use`
    + `:tool_result` (name = inner key minus its `ToolCall` suffix; result surfaced
    from `tool_call.<kind>ToolCall.result`), `thinking` → `:thought` (the same
    reasoning lane grok uses). Cursor runs now render structured tool cards and a
    folded reasoning card instead of a flood of "OTHER" badges.
  - **Run-detail header showed "Agent kind: nil" for every live run.** The header
    surfaced `Status.agent_kind` (nil until termination) instead of the adapter
    resolved at run start. Now renders the resolved `@agent_kind` (`agent_label/2`),
    falling back to the Status field, so a running run's agent is legible.
  - **No token usage on the run-detail page.** Added a `Tokens` row
    (`token_label/2`) parsing the captured transcript with the same per-adapter
    parser the KPI ledger uses; agents that report no usage render "—".
  - **Codex's multiple `agent_message` items mashed into one wall of text.** The
    renderer folds consecutive `:assistant_text` (correct for grok's token deltas);
    codex now emits a trailing blank line per complete message so the fold separates
    them into paragraphs (grok's per-token text path is untouched).
  Found dogfooding non-default agents. (The `:unknown` "unknown chunk" rows for
  non-JSON agent output — codex skill-load stderr, grok ANSI noise — are kept
  by design: Task 86's "never silently drop" contract.)

- **Cursor token usage now parsed — the KPI page no longer shows blank tokens
  for cursor-dispatched runs.** `Harness.TokenUsage.parse(:cursor, …)` routed
  cursor through the Anthropic stream parser, which reads snake_case
  `input_tokens`; cursor actually reports cumulative usage on its terminal
  `result` event with **camelCase** keys (`inputTokens` / `outputTokens` /
  `cacheReadTokens` / `cacheWriteTokens`), so every cursor run parsed to all-`nil`
  (16 stored records measured nothing). Added a dedicated `parse_cursor/1` +
  `from_cursor_usage/1` reading the real shape; the stale "cursor mirrors
  Anthropic" test (which fed snake_case and so never caught this) is replaced
  with a real-cursor-shaped fixture. Found dogfooding non-default agents. (Grok
  is *not* affected: its `end` event can carry `usage` and `parse_grok/1` already
  extracts it defensively, but it isn't emitted every run/release — both captured
  grok runs' `end` events had no `usage` key, so all-`nil` is correct-when-absent.
  Antigravity is plain text with no usage. Surfacing all-`nil` as "—/not reported"
  rather than a misleading 0 on the KPI page is a display follow-up, not a parser bug.)

- **MCP tool names now use "-" (not "__") as the group/action delimiter.** Descripex
  emits `<group>__<action>` (e.g. `dispatch__task`); when MCP clients (grok, others)
  qualify as `<server>__<tool>`, this produced `harness__dispatch__task` (two "__"),
  causing "Skipping MCP tool" rejects for the entire harness surface. The fix is
  centralized in `Harness.Manifest` (the single source of truth for both the MCP
  server and `Harness.Chat.Tools`): post-process Descripex output, expose
  `tool_name_delimiter/0`, update the two reverse-lookup splits. All 35 tool names,
  docstrings, and tests updated at the convention source. Grok-style qualified names
  now contain exactly one "__". Added test asserting the invariant. Task 135.
- **The cron poller no longer re-dispatches completed-but-unlanded tasks every
  tick — the run lifecycle now claims a dispatched task `in_progress` on start.**
  Under `landing_policy: :manual`, a run could finish green yet stay unlanded, so
  the task remained `pending` and the next tick re-dispatched the same green work
  forever (Oban `{project, item}` uniqueness only dedups *in-flight*, not
  completed-then-pending). `Harness.Run.Worker` now best-effort claims the task
  `in_progress` before `start_run` (a failed writeback logs and continues, never
  fails the run) via the new `Harness.Roadmap.mark_in_progress/2`; a green-unlanded
  run *stays* `in_progress` (only an explicit land moves it to `done`), while a
  terminal failure reverts to `pending` (`Roadmap.mark_pending/2`, not `blocked`)
  so a later tick retries — transient failures snooze without reverting. Writeback
  owner is the run lifecycle, not the poller. Delivered by grok via harness
  dogfooding (run `run-1780277844276-9fec2836`, verdict `pass`), Task 131.
- **Grok (and any token-streamed) chain-of-thought now renders as one collapsed
  reasoning card instead of a wall of empty `THOUGHT` rows.** Grok streams
  reasoning token-by-token — one `{:system, kind: :thought}` event per token —
  and the run-detail transcript reducer emitted a separate block per event while
  the `eyebrow/1` renderer deliberately drops the `data` payload. A single thought
  therefore rendered as ~150 bare "THOUGHT" labels with the text discarded
  (the raw stream had every fragment; the parsed view threw it all away). The
  reducer now folds consecutive `:thought` events into one `:thought` block
  (mirroring the `:assistant_text` accumulator), rendered as a collapsed
  `<details>` "reasoning" card carrying the concatenated text — dim and secondary
  to assistant output. Found dogfooding a grok dispatch of Task 131.
- **Per-project Oban dispatch + landing queues now actually start at boot, so
  enqueued runs no longer sit `available` forever.** `Harness.Oban.ensure_project_queue/1`
  and `queue_headroom?/1` guarded queue starts on `Process.whereis(Harness.Oban)`,
  which is always `nil` — Oban registers its instance through `Oban.Registry`
  (a `{:via, ...}` name), never as a globally named process. The guard therefore
  short-circuited every start: config-registered projects' queues never left
  `[:cron]` at boot, and cron-enqueued `Run.Worker` jobs had no producer to run
  them (observed 2026-05-31: 5 jobs stuck `available` on `project_harness` until
  a manual `Oban.start_queue`). Both guards now use `Oban.whereis/1`, the
  registry-aware liveness check. Autonomous dispatch was inert before this fix
  (Task 133).
- **Autonomous cron polling no longer dispatches `handbuild` tasks headless, and
  now dispatches the whole parallel-safe batch per tick instead of one task.**
  `Harness.Cron.RoadmapPoller` selected work via `Harness.Roadmap.ingest(:next)`,
  which shells `rmap next` — a surface with no `--dispatchable`/negative-marker
  filter, so it returned `handbuild`-marked UI tasks that then idle-timed-out
  under headless dispatch (observed: task 127, a LiveView, dispatched to Claude).
  It also enqueued only the single `:next` task per tick. The poller now selects
  via new `Harness.Roadmap.ready/1` (`rmap ready --dispatchable --fields id,model,markers`),
  which excludes `handbuild` and returns the full deps-done set, and enqueues one
  `Run.Worker` per task — Oban's per-project queue caps concurrency at the
  project's `concurrency_cap` (the harness self-project now sets `concurrency_cap: 10`).
  Inserts are unique over `{project_name, item_id}` across non-terminal states, so
  a later tick won't re-enqueue an in-flight task. Each task routes to its agent
  via the `model` field (the harness roadmap's convention), then `cx`/`csr`
  markers, else `:claude`; a task whose agent is operator-disabled or
  quota-unavailable is skipped via `AgentRegistry.select/2`.
- **Run records (and chat sessions) written by a prior build are no longer
  silently dropped on read.** `Harness.ResultStore.File` and `Harness.Chat.Store`
  decoded their persisted `.term` files with `:erlang.binary_to_term(body, [:safe])`;
  `[:safe]` rejects any term referencing an atom not currently interned in the
  running BEAM, so a record/session whose `reason`/`agent`/`adapter` atom came from
  an older build failed to decode and vanished from the dashboard run history, the
  per-agent KPI ledger, and `load_batch/2` (observed: 30 of 45 real run records
  invisible). These are harness-owned files written by harness's own
  `term_to_binary`, not untrusted input, so `[:safe]` guarded a non-existent threat
  at the cost of dropping valid data. Both now decode without `:safe`; the existing
  `rescue ArgumentError` still catches genuinely torn bytes.

### Added

- **`roadmap__ready` MCP/chat tool.** `Harness.Roadmap.ready/1` — the parallel-safe,
  headless-dispatchable task set the cron poller fans out (`rmap ready --dispatchable`,
  `handbuild` excluded; Task 129) — is now descripex-`api()`-annotated, so it surfaces
  as `roadmap__ready` on the `/harness/mcp` endpoint and the in-process chat tool
  dispatcher. An external orchestrator can read the fan-out-safe batch as structured
  data without shelling rmap.
- **Per-agent enable/disable from the Settings page.** An operator takes an agent
  out of dispatch rotation (a flaky CLI, an exhausted paid plan, a model under
  evaluation) with a toggle on `/harness/settings` — an **Agents** card listing all
  six adapters with an enabled/disabled pill and a "not installed" hint when the CLI
  binary is off PATH. A disabled agent is skipped by `Harness.AgentRegistry.select/2`
  (the universal dispatch gate, so runs, batches, and cron ticks all honour it),
  returning `:no_available_agent` when no enabled+capable adapter remains.
  Operator-disable is **persisted** (`~/.harness/agent_settings.term`, mirroring
  `Harness.Chat.Store` / `Harness.Cron.Settings`; disable with
  `config :harness, :agent_settings, false`) and seeded into app env on boot — a
  durable operator decision, deliberately distinct from the transient,
  clears-on-restart quota hint (`available?/1`) it composes with (`select/2` needs
  both enabled AND available). Agents default ON; disabling is opt-in. Flips are
  audited at info level naming the actor. New module `Harness.Agent.Settings`.
- **Runtime cron-autonomy toggles — master + per-project (Tasks 109/110).** A
  persisted, dashboard-driven kill-switch for autonomous roadmap polling. The
  master flag (the fleet-wide incident switch) and a per-project flag are flipped
  at runtime from a dedicated **Settings page** (`/harness/settings`, linked from
  the navbar) — toggle switches over the existing dark design system, with a
  resolved-status pill and an armed/dispatching/paused state per project — no
  config edit, no restart. Effective autonomy is `master AND project`: a project dispatches only
  when both are on, so a new project stays non-autonomous (flag defaults OFF)
  until an operator opts it in, and the master switch pauses the whole fleet at
  once. The panel shows the resolved poll status (`RoadmapPoller.status/0`) and
  warns when master is ON but no project is enabled (nothing would dispatch).
  Flips are audited (info-level log naming the actor) and persisted to a
  file-backed term store (`~/.harness/cron_settings.term`, mirroring
  `Harness.Chat.Store`; disable with `config :harness, :cron_settings, false`),
  so a choice survives a BEAM restart — seeded back into app env on boot before
  Oban starts. The `Oban.Plugins.Cron` entry now registers **unconditionally**
  (previously gated on the boot-time `enabled` flag): the tick is always
  scheduled, and whether it *dispatches* is the live gate inside
  `RoadmapPoller.perform/1` — without this, toggling autonomy on from a
  disabled-at-boot node had no scheduled tick to act on. Per-project skips log at
  info level (no longer a silent debug line). `%Harness.Project{}` and
  `ProjectRegistry.register/1` are unchanged — absence-means-off lives entirely
  in the settings store.
- **Per-agent KPI aggregation over run records (Task 114).** `Harness.AgentKPI`
  rolls a list of `%Harness.Run.LogRecord{}` (e.g. from
  `ResultStore.list_run_records/1`) up by `agent` into a per-agent ledger:
  `success_rate` (`:pass` / total), `first_attempt_pass_rate` (`:pass` with zero
  repairs), `duration_ms` median + p90 (nearest-rank), mean tokens
  (input/output/total), mean `repair_attempts`, and a `cost_to_green` composite
  (mean total tokens per `:pass` run, `nil` when an agent has no green runs). No
  new capture — every input field already exists on `LogRecord`. Pure functions
  only: the caller supplies the records, so the rollup is testable without I/O.
- **Per-agent KPI dashboard (`Harness.Dashboard.KPILive`, Task 115).** A
  sortable per-agent trust ledger at `/harness/kpi` (linked from the dashboard
  topbar) that renders `Harness.AgentKPI.aggregate/1` over every persisted run
  record: run count, success rate, first-attempt-pass rate, mean repair
  attempts, mean tokens, and cost-to-green — one row per agent, every column
  click-to-sort. An empty store renders an explicit "no run records yet" state
  rather than a table of zeros. Reads the store at mount and re-aggregates on
  each `:harness_run_settled` fleet event (the only event that mints a new
  record). Resolves the Task 81 (`CompareLive`) relationship as a **deliberate
  sibling**: this is the fleet-wide aggregate ledger, Task 81 is the
  per-comparison A/B surface — neither subsumes the other.
- **Run change-set view on the run-detail page.** Each run now shows what it
  changed: an in-flight run lists the files the agent is editing (from its
  transcript tool calls), and a settled run shows the actual git diff — file
  list with `+/−` proportion bars and a colorized unified patch — read on
  demand from the run's `harness/<run_id>` branch (no diff is persisted). A
  branch the autonomous lander has already merged/cleaned up degrades to a
  graceful note. (`Harness.RunDiff`, `Harness.Dashboard.Live`,
  `Harness.Dashboard.Components`.)
- **JSON-native dispatch observe / control / fan-out surface.** The flat
  `dispatch__*` MCP + chat tool family gained the run-lifecycle half a JSON
  orchestrator was missing: `dispatch__status` / `dispatch__transcript` /
  `dispatch__transcript_events` follow a live run by `run_id`, `dispatch__cancel`
  kills it (idempotent), `dispatch__bundle` fans the next session-sized roadmap
  bundle out as one Oban-backed job per task (delegatable adapters only —
  claude/codex/cursor), `dispatch__compare` runs one task A/B across N adapters
  in isolated worktrees, and `dispatch__verdict_detail(run_id)` reads a settled
  run's per-failed-check captured output. The first three are generated by a new
  `Harness.Dispatch.RunTool` compile-time DSL (`defrun_tool/1`, schema-validated
  via `nimble_options`) that wraps the uniform `{:ok, _} | {:error, :not_found}`
  `Harness.Run` observers. `%Harness.Run.LogRecord{}` now carries `check_output`
  — the bounded (16 KB tail-truncated per check, failing checks only) stdout+stderr
  of each failed check — so `dispatch__verdict_detail` works after the run process
  is gone.

- **Persisted run history in the dashboard (Task 105).** The dashboard index and
  drill-down previously read only live state, so every settled run vanished from
  view on a BEAM restart even though it persists durably as a
  `%Harness.Run.LogRecord{}` under `~/.harness/results`. The index now renders a
  "Run history" table merged from the `ResultStore` (deduped against live runs —
  the live entry wins — newest-first, capped), and drilling into a settled run
  rebuilds its status snapshot (`Harness.Run.Status.from_log_record/1`) and
  replays its transcript from the record via the per-agent parser. Display-only;
  no new storage layer. `mix harness.status` terminal output and the topbar
  tallies stay live-only.

  The dashboard run tables are now **event-driven**: a new fleet PubSub feed
  (`Harness.Dashboard.RunFeed`, topic `harness:runs`) carries
  `{:harness_run_update, status}` on each non-terminal run transition and
  `{:harness_run_settled, status}` on settle, and both tables are
  `Phoenix.LiveView` streams patched per-row from those messages. This replaces
  the previous 1-second tick that re-read and decoded the entire persisted
  results directory from disk on every tick per connected client — history now
  loads once at mount and patches on settle. Sidebar metadata (projects,
  adapters, quota) refreshes on a slow 5-second metadata-only tick (no disk).

  The dashboard **project filter** now works: runs carry a `project_name`
  (threaded onto `Harness.Run.Status` and `%LogRecord{}` from the run's
  `%Project{}`), and the project switcher is a `phx-change` form (a bare
  `<select phx-change>` outside a form silently dropped the event), so selecting
  a project narrows both the active and history tables to that project and "All
  projects" restores the full view. Records persisted before `project_name`
  existed decode as "no project" and appear only under "All projects".

- **Mergeable-bar verification preset — `:elixir_precommit` (Task 97).** A green
  `:elixir` preset verdict could still be unmergeable under the project's own
  `mix precommit` (the divergence surfaced on Task 94: harness graded green
  while the project's 80% coverage gate measured 75.92%). The new
  `:elixir_precommit` preset mirrors that mergeable bar — on top of the default
  stack it adds `format --check-formatted`, `compile --warnings-as-errors`, a
  coverage threshold on `test`, and `doctor --raise` — so a project opts into
  "verdict ⇒ mergeable" via `preset: {:elixir_precommit, cover_threshold: 80,
  exclude: [:integration]}` in its registration config. The gates are ordinary
  `Harness.Verification.Check`s, so they flow through the existing per-check
  verdict display in the dashboard run-detail. The harness self-project now
  registers against `:elixir_precommit`; `:elixir` stays the lighter default.

- **Blocking dispatch — `dispatch__await` (Task 103).** A blocking companion to
  `dispatch__task` for the chat/MCP surface. Where `dispatch__task` returns a
  `run_id` the orchestrator must then poll, `Harness.Dispatch.await/5`
  (`dispatch__await`) subscribes the calling process to the run and **blocks
  until it settles**, returning a compact verdict summary (state, reason,
  per-check results, repair attempts, diagnostics) as the tool result — a
  tool-equipped LLM driving harness gets the answer in one call instead of a
  poll loop. The wait is bounded by a `timeout_ms` argument (default 30 min);
  on expiry it returns a structured `:timed_out` summary carrying the `run_id`
  (the run keeps going and stays observable/cancelable) rather than wedging the
  tool call. The bulky check output and raw agent transcript are dropped from
  the summary; read the `%Run.Result{}` / `LogRecord` for those.
  `dispatch__task` (fire-and-forget) is unchanged alongside it.

- **Per-run token capture — efficiency signal.** Harness now parses each
  adapter's raw transcript for input/output token counts (`Harness.TokenUsage`)
  and threads them through `%Harness.Run.Result{}`, `%Harness.Run.LogRecord{}`,
  and `%Harness.Batch.AgentEvaluation.Entry{}` — so an A/B comparison can weigh
  *token efficiency* (did the adapter solve the task in 50k tokens or 500k?),
  not only the binary pass/fail verdict, and cumulative burn becomes the input
  signal for predictive quota fail-over. Counts are summed across repair
  attempts, so a multi-attempt run's burn is attributable. Per-adapter parsing
  (Claude/Cursor stream-json `usage`, Codex `turn.completed`, Pi
  `message_update` deduped by `responseId`, Grok terminal `end`); a wire format
  that carries no usage records an empty usage (all-`nil`) and never crashes.
  Not dollar accounting — agents run on flat subscriptions.

- **Per-stack working directories — multi-language monorepos.** A project now
  holds a *list* of check stacks (`%Harness.Project{}.check_stacks`) instead of
  one, and each `%Harness.CheckStack{}` carries a `workdir` (relative to the
  worktree root). Because a git worktree is always repo-root-granular,
  `Harness.Verification.run/2` runs each stack's checks in its own
  subdirectory and flattens the results into a single verdict (green iff every
  stack is green). This lets a polyglot repo — e.g. a Rust crate in `rust/`
  next to a Phoenix app in `elixir/` — be graded correctly from one
  repo-root worktree; previously checks always ran at the worktree root, so a
  subdirectory build (rexex's `rust/Cargo.toml`) failed unrecoverably. Project
  registration gains a `stacks: [[preset:/check_stack:, workdir:], …]` form;
  singular `preset:`/`check_stack:` registration (and the `:check_stack` /
  `:checks` run options) remain valid as the one-stack-at-the-repo-root case.
  A misconfigured `workdir` now returns a clear `{:workdir_not_found, dir}`
  instead of a cryptic per-tool "manifest missing" failure.

- **v0_8 chat-orchestrator surface — roadmap browsing, playbooks, flat
  dispatch.** Builds on the v0_7 chat/MCP foundation so an orchestrator can
  pick *and* dispatch work end-to-end through tools, never by shelling `rmap`
  into the live checkout. `Harness.Roadmap.list/2` + `next_bundle/1`
  (`roadmap__list` / `roadmap__next_bundle`) expose a registered project's
  roadmap as JSON-native maps. `Harness.Playbooks` (`playbooks__list` /
  `playbooks__get`) serves version-controlled orchestration recipes from
  `priv/playbooks/*.md`, surfaced in the dashboard chat as prefill chips.
  `Harness.Dispatch.task/4` (`dispatch__task`) collapses the struct-passing
  `ingest → start_run` flow into one flat call taking only JSON scalars
  (project name, task selector, adapter, scrub-key) and returning a
  `run_id` — with the Claude OAuth secret-scrub and the non-delegatable
  ingest-then-dispatch two-step handled internally. The MCP `tools/list`
  now excludes struct-arg tools a stateless JSON caller cannot drive
  (`supervisor__start_run`, the `batch__*` / `agent_evaluation__*` tools);
  they remain on the full in-process Elixir driver surface. Companion fixes:
  keyword-typed params decode from JSON objects without crashing
  `Keyword.get/3`, and integer-keyed `tasks.toml` ids coerce to strings on
  ingest.
- **Chat session persistence + index page (Task 93).** Chat transcripts now
  survive a BEAM restart. `Harness.Chat.Store` is a file-backed term store
  (one `:erlang.term_to_binary` file per session under
  `config :harness, :chat_store, root: …`, written via a `.tmp` sibling +
  atomic rename; `false` disables it). `Harness.Chat.Session` persists its
  messages after each completed turn (bounded to the most recent 200,
  mirroring the live buffer cap) and rehydrates them on init, so reopening
  `/harness/chat/<session_id>` replays the prior turns. The bare
  `/harness/chat` route is now a session **index** listing live sessions
  (`Harness.Chat.Supervisor.list_sessions/0`) merged with persisted-but-dead
  ones — each with a derived label, message count, last-activity, and a deep
  link; a "New chat" button mints a fresh session.
- **v0_7 chat orchestrator (5 shipped, 1 superseded).** Harness now ships
  a third consumer surface alongside the verified-run lifecycle and the
  cheap driver path: a natural-language chat session backed by `claude -p`
  on the Claude subscription tier, with the same harness toolset exposed
  externally as a spec-compliant MCP server. `Harness.Chat.Session` runs
  the multi-turn tool-call loop; `Harness.Chat.Claude` is the default
  backend (raw-Port spawn of `claude -p --output-format stream-json`,
  `ANTHROPIC_API_KEY` scrubbed to force OAuth/subscription, per-session
  cwd for `--continue` resume); `Harness.Dashboard.MCPServer` (anubis_mcp,
  JSON-RPC 2.0 over Streamable HTTP at `/harness/mcp`) exposes the toolset
  to external orchestrators via standard `.mcp.json` HTTP transport;
  `Harness.Chat.Tools` is the single registry both the in-process loop
  and the external MCP surface dispatch through. Non-tool chat works
  end-to-end via the dashboard chat panel.
- **Live MCP tool-use end-to-end (Tasks 83 + 84).** The anubis Streamable
  HTTP transport now starts cleanly under `iex -S mix` — `claude -p`'s
  `initialize` (protocol "2025-11-25") returns 200, `tools/list` surfaces
  the harness manifest, and a tool-needing prompt drives a real
  `tools/call` round-trip the model summarises back. Fix was a one-line
  `transport: {:streamable_http, start: true}` on the `MCPServer` child
  spec in `Harness.Application`: anubis's auto-detect for whether to
  start the transport falls through to `:phoenix, :serve_endpoints`,
  which is `false` for harness because it's not a `phx.server` app
  (the dashboard is one opt-in surface, not the app's primary identity).
  Task 84 added `Harness.Dashboard.ErrorHTML` so the formerly-cascading
  500 — `Phoenix.Template` crashing on a missing template while trying
  to render the underlying error — no longer hides real stack traces.
- New dep `{:anubis_mcp, "~> 1.6"}` (Task 79 v1 audit rework). Direct
  runtime dep that supplies the MCP server behaviour and Streamable HTTP
  transport plug; transitively pulls in `peri` (validator) and `finch`
  (HTTP client) — Bandit on 4018 forwards `/harness/mcp` to it.
- Dev environment now self-registers the harness checkout as the default
  `"harness"` project on boot (Task 72). New `config/dev.exs` populates
  `config :harness, :projects`; `config/config.exs` conditionally imports it
  via `if config_env() == :dev`. `iex -S mix` therefore exposes
  `Harness.ProjectRegistry.lookup("harness")` without a manual
  `register/1` step, making the dispatch examples in
  `skills/harness-driver/SKILL.md` and `docs/dogfooding-workflow.md`
  literally true against the live node. `:test` and `:prod` are unchanged
  (no auto-registration). `config/dev.exs` now also conditionally imports a
  gitignored `config/dev.local.exs` (template: `config/dev.local.exs.example`)
  so operators can register host-local target projects without dirtying
  tracked config — the local file's `config :harness, :projects` call
  replaces the default list, so it must repeat the `"harness"` self-entry.
- Same-task A/B agent evaluation (Task 33). `Harness.Batch.AgentEvaluation.compare/4`
  fans one roadmap item to N adapters in parallel under the existing batch fan-out;
  `Harness.Batch.run_pinned/3` is the lower-level entry that pairs each item with a
  specific adapter. Per-agent metrics (verdict, repair_attempts, duration_ms,
  first_attempt_failed_check_count, agent_diff_size) collect into a `Comparison`
  struct as an additive layer — the verification stack stays the binary pass/fail
  grader. Adapter fail-over never crosses pins.
- Cross-agent grader as an opt-in repair-loop move (Task 59). When the same
  verification check fails twice in a row, the `Harness.Run` gen_statem can spend
  one repair attempt routing the failing diff through `Harness.AuditReview` for an
  opposite-agent verdict (Codex grading Claude, Claude grading Codex), then thread
  the rationale into the same-agent's next repair prompt. Disabled by default
  (`config :harness, :cross_agent_repair, enabled: false`); `:grader` required for
  implementers outside the `:claude ↔ :codex` auto-pair.
- Orchestration playbooks (`Harness.Playbooks`). Version-controlled markdown
  recipes — dispatch-single-task, dispatch-bundle, ab-adapter-compare,
  audit-grade-fix — embedded at compile time from `priv/playbooks/*.md` and
  surfaced as `playbooks__list` / `playbooks__get` tools on the same chat/MCP
  surface, so the orchestrator can fetch a ready-made tool sequence instead of
  assembling one.
- Structured roadmap browse (`Harness.Roadmap.list/2` + `next_bundle/1`,
  tools `roadmap__list` / `roadmap__next_bundle`). Resolves a registered
  project name to its roadmap and returns tasks/bundles as JSON-native maps, so
  the orchestrator picks a task id through a harness tool rather than shelling
  `rmap` from harness's own cwd (wrong root, and broken for `{:github, _}`
  sources).
- Run-detail transcript reworked from a raw stream-json `<pre>` dump to a
  chat-style parsed-event view (`<.transcript_view>`), grouping assistant text,
  tool-call/result pairs, system lines, and passthrough output; `?raw=1` on the
  run URL falls back to the legacy raw buffer.

### Changed

- **Semantic gate decoupled from auto-land (Task 123).** The cross-family
  semantic gate (Task 99) re-checks a green verdict against the task's
  acceptance criteria with an opposite-family grader, but its trigger was
  hardcoded to "on iff the project would auto-land". harness's own self-project
  lands manually, so its dogfooding dispatches ran with the one AC-aware check
  off — Task 108 settled green while objectively incomplete and was
  hand-finished on land. The trigger now consults a project-level
  `semantic_gate` mode on `%Harness.Project{}` — `:always` (gate every green
  run, even under manual landing), `:auto_land_only` (the default; preserves the
  original gate-iff-auto-land behaviour), or `:off` (never gate). A per-dispatch
  `semantic_gate: [enabled: true | false]` run opt — surfaced as a `semantic_gate`
  boolean on the `dispatch__task` / `dispatch__await` tools — forces the gate
  on/off for a single run regardless of landing policy. Default behaviour is
  unchanged (manual-landing projects stay un-gated unless explicitly enabled);
  the harness self-project registration (`config/dev.exs`) opts into
  `semantic_gate: :always` so its dogfooding now gets green-verdict scrutiny.
  The gate machinery (grader pairing, sentinel extraction, `:semantic_rejection`
  repair route) is reused from Task 99 unchanged — only the when-it-fires
  predicate moved.
- MCP surface reworked from a custom REST endpoint (`Harness.Dashboard.MCP`,
  `GET /harness/mcp/tools` + `POST /harness/mcp/call`) to a spec-compliant
  MCP server (`Harness.Dashboard.MCPServer`, JSON-RPC 2.0 over Streamable
  HTTP via `anubis_mcp`) on the same `/harness/mcp` path (Task 79 v1 audit
  rework). External consumers can now drive harness via standard
  `.mcp.json` HTTP transport — a prerequisite for Task 82's `claude -p`
  chat backend. `use Anubis.Server` provides `initialize`, `ping`, and
  prompts/resources defaults via a catch-all clause appended by
  `@before_compile`; harness overrides `tools/list` + `tools/call` to
  reuse `Harness.Chat.Tools` (the in-process chat orchestrator's registry
  + dispatcher), giving one source of truth for both surfaces. Supervised
  process gated on `:dashboard, :enabled` because the Streamable HTTP
  transport requires the Phoenix endpoint.
- `Harness.Chat.Schema.validate/2` now accepts both string-keyed and
  atom-keyed JSON-Schema maps via a single internal `fetch/3` helper.
  Previously only string keys (`%{"type" => "object", ...}`) validated;
  atom-keyed schemas (`%{type: "object", ...}` from
  `Descripex.MCP.tools/1`) silently no-op'd and let downstream code
  emit a generic `path: "#"` violation. Now the validator produces
  precise per-field violations (`path: "#/name"`) regardless of key style.
- `Harness.AgentAdapter` now exposes `permission_flag/2` and `resume_args/1`
  as shared public helpers, hoisted out of the Antigravity / Claude / Cursor
  / Grok / Pi adapters where they were byte-identical (same spirit as
  Task 27's classify/terminate/model_args hoist and Task 39's rule-injection
  hoist). `permission_flag/2` is term-agnostic — it returns the raw stored
  value, so adapters with string-flag modes (Antigravity/Claude/Grok) and
  Cursor's list-flag mode all flow through the same helper. Behavior
  preserved; error tuples (`:unsupported_permission_mode`,
  `:unsupported_session_token`) unchanged. Codex keeps its own
  permission/session shape (id-based resume, list-of-atoms modes) and does
  not adopt either helper.

### Fixed

- Multi-required-param tools dispatched arguments to the wrong positions
  (descripex 0.7 `param_order`). `Harness.Chat.Tools` ordered the positional
  `apply/3` args by `Map.keys/1` (hash order), so a tool like `roadmap__list`
  could receive its `status` value in the `project_name` slot. Now ordered by
  declaration via descripex 0.7's `param_order`; bumped `{:descripex, "~> 0.7"}`.
- Correctness + hardening pass from an independent multi-agent review of the two
  newest subsystems (chat/MCP, Oban dispatch) plus the OTP core. Notable fixes:
  the orphan-kill race in `AgentAdapter.OSProcess.kill/1` (the OS process could be
  reaped and its pid recycled before the external `kill` landed, so the signal now
  precedes the port close); a `MatchError` crash in `Worktree.diff_size/1` on
  unexpected `git diff --numstat` output (binary files); `Worktree.Isolation`
  allowlist patterns containing `/` (e.g. `config/*.exs`) now glob against the full
  path instead of the basename, so they actually match; chat-session terminal
  events (`loop_detected`, `backend_error`, `max_history_bytes`) now broadcast to
  stream subscribers like the abort path already did; UTF-8-safe truncation in the
  dashboard chat buffer (a byte-count prefix no longer splits a multi-byte
  codepoint); a catch-all in `Dashboard.MCPServer` so a novel `Tools.dispatch`
  error shape can't crash the request handler; `Chat.Tools` now distinguishes an
  explicit `null` argument from an absent one; the Oban worker now snoozes
  transient setup failures (boot-race project lookup, ingest/start-run hiccups)
  instead of permanently cancelling them, preserving Oban's restart-resilience,
  while genuinely malformed job data still cancels; `ResultStore.File` writes are
  now atomic (sibling `.tmp` + `File.rename/2`) so a racing reader can't observe a
  torn term file; and `Oban.QueueBootstrap` logs (rather than silently swallowing)
  a Postgres-not-up-at-boot failure.
- `Harness.ResultStore.File.list_run_records/2` now logs and skips undecodable
  term files instead of halting on the first one (Task 73). Previously a single
  atom-stale or corrupt file under `~/.harness/results/runs/` returned
  `{:error, {:invalid_term_file, _}}` for the whole query, masking every
  healthy sibling — breaking the Tidewave dispatch-and-observe pattern
  documented in `skills/harness-driver/SKILL.md`. `collect_records/2` now
  reduces with `Enum.reduce/3` (no short-circuit on `{:error, _}`),
  `Logger.warning`s the reason, and returns `{:ok, [healthy_records]}`.
- Batch test gate-file hygiene no longer leaks stale coordination files or
  orphaned polling shells (Task 70). Gate paths now register per-test cleanup,
  the fake adapter's shell waiter exits if it becomes reparented, and the batch
  test module clears `harness-batch-gate-*` files before and after the suite.
- `Harness.Run` now skips main-checkout pollution detection for adapters that
  declare `worktree_isolation: true` (Task 66). The capability is treated as the
  trust boundary: verified-isolation adapters no longer fail with
  `:checkout_polluted` because an operator or parallel session changed the
  source checkout while the agent worked in its run worktree. Adapters declaring
  `worktree_isolation: false` are still rejected before spawn.
- `Harness.Batch.fill_slots` no longer settles the entire pinned queue when one
  pinned adapter is unavailable (Task 67). In non-pinned mode every queued item
  shares the same adapter list, so one select failure still settles the whole
  queue (unchanged); in pinned mode (`run_pinned/3`, `AgentEvaluation.compare/4`)
  each slot owns its own adapter, so only the head is settled and the rest
  recurse with their own pinned adapters. Surfaced by the Round-5 audit of the
  Task 33 A/B mode delivery.
- `Harness.Batch.AgentEvaluation.from_batch/3` now raises `ArgumentError` on
  adapter/results length mismatch (Task 68). The previous `Enum.zip` would
  silently truncate to the shorter list, dropping entries from the comparison
  without telling the caller.
- `Harness.Worktree.Isolation` pollution allowlist now tracks both source and
  destination of `R old -> new` porcelain lines (Task 69) — an agent moving
  `lib/foo.ex` → `.claude/foo.ex` no longer evades pollution detection because
  the destination is allowlisted. The default allowlist gained a `**/<name>`
  recursive-basename pattern (gitignore-style); `.DS_Store` upgraded to
  `**/.DS_Store` so `docs/.DS_Store` is also ignored, not just the repo-root
  copy.
- Codex adapter now pins its working root via exec-level `--cd <worktree>` in
  addition to the Port's `:cd` (Task 41). Without the flag, Codex's heuristic
  workspace resolution could follow a linked worktree's `.git` pointer back to
  the main checkout's common git-dir and silently edit the parent repo — same
  shape as Task 32's Antigravity bug.
- `Harness.Worktree.Isolation` checkout-pollution diff now filters porcelain
  lines against an allowlist (Task 60). Defaults cover `.claude/`, `.DS_Store`,
  and common editor lock/temp files; overridable per project
  (`%Harness.Project{}.pollution_allowlist`), per run
  (`Harness.Run.Supervisor.start_run/4`'s `:pollution_allowlist`), or via
  app config. Roadmap files are deliberately NOT allowlisted — a genuine
  agent mutation to roadmap state is still a bug worth catching.
- Failure classification (Task 64) now clips `Outcome.output` and each
  `CheckResult.output` to its trailing 4 KiB before quota-pattern matching.
  Agents constantly read source and docs containing the trigger words
  (`quota`, `rate limit`, `subscription`), so matching the full stream-json
  transcript was wildly false-positive-prone — a benign mid-run source read
  could short-circuit the repair loop with a false `:quota_exhausted`
  classification. Terminal API errors (`billing_error`, HTTP 429, etc.)
  still detect correctly when they appear in the agent's terminal envelope.
- Dashboard transcript pane now backfills on mount instead of starting empty
  (Task 63). The per-run transcript at `/harness/runs/:run_id` was fed by
  fire-and-forget `Phoenix.PubSub` broadcasts, so opening the page mid-run
  showed "Waiting for output…" until the next chunk arrived — often minutes
  later for a quiet Claude session. The `Harness.Run` gen_statem now owns a
  bounded 200 KiB transcript buffer + a monotonic seq counter; the driver's
  `:on_output` callback sends each chunk to the gen_statem (which appends and
  re-broadcasts with seq); the LiveView subscribes first, fetches the buffer
  via the new `Harness.Run.transcript/1`, then drops PubSub messages whose
  `seq <= last_seq` to dedup chunks that landed during the snapshot call.
  Broadcast tuple is now `{:harness_transcript, run_id, seq, chunk}` (was
  3-element). `Harness.Dashboard.Transcript.append/3` is the shared trim
  helper so producer and consumer agree on the 200 KiB cap.

### Added

- Phoenix LiveView dashboard with embedded Oban Web (Task 50, closes milestone
  v0_5). `Harness.Dashboard.Endpoint` boots a standalone Bandit listener on
  port 4018 (configurable via `:harness, :dashboard, port:` or
  `HARNESS_DASHBOARD_PORT`), gated by `:dashboard, :enabled` plus a
  `Code.ensure_loaded?(Bandit)` check so mountable consumers can route the
  LiveView into their own endpoint instead. `Harness.Dashboard.Router` mounts
  `oban_dashboard("/harness/oban", oban_name: Harness.Oban)` for queue-centric
  introspection, then `live("/harness", ..., as: :dashboard)` and
  `live("/harness/runs/:run_id", ..., as: :dashboard)` for the harness-native
  view. `Harness.Dashboard.Live` renders a project switcher off
  `Harness.ProjectRegistry.list/0`, per-bucket counts and an active-run table
  off `Harness.StatusView.snapshot/0` + `classify/1`, and a per-run drill-down
  off `Harness.Run.status/1` — kept fresh by a 1s `:tick`. A live transcript
  pane subscribes to `Phoenix.PubSub` topic `harness:run:<id>:transcript`,
  fed by a new `:on_output` callback on `Harness.AgentAdapter.Driver.run/3`
  via `Harness.Dashboard.Transcript.broadcast/2` — every output chunk the
  agent emits is published to the topic, the LiveView keeps the last 200 KiB
  in a bounded buffer. Bandit flipped `optional: true` so a mountable
  consumer is not forced into a second HTTP server.
- GitHub project sources: `%Harness.Project{}` now accepts `source: {:github, url}`
  alongside the existing `{:local, path}`. On first run, harness clones the URL
  into a per-project cache directory under `:harness, :project, :cache_root`
  (default `~/_DATA/harness/projects`); on every subsequent run, harness
  `git fetch`es and fast-forwards the default branch, so a run never grades
  against a stale `main`. Cache-recovery is transparent: if the cache directory
  was removed between runs, the next call re-clones. New modules
  `Harness.Project.Source.Local` and `Harness.Project.Source.Github` carry the
  per-variant surface (`url/1`, `local_path/2`, `ensure_local/2`).
  `Harness.Worktree.create/2` now calls `Project.ensure_local_repo/2` before
  branching, so a `{:github, _}` project transparently boots from a fresh clone
  or a fetched cache. (Task 47)
- Precommit gate now fails on Sobelow findings (`sobelow --exit --skip`) and
  ships a `mix sobelow.baseline` alias for deliberately marking the current
  findings as skippable.
- Oban-backed dispatch for registered projects: runtime deps now include Oban,
  Ecto SQL, and Postgrex; `Harness.Repo` owns the Postgres connection; Oban
  jobs persist one run per roadmap item in per-project queues named
  `project_<name>`; `Harness.Run.Worker` spawns the existing run gen_statem and
  maps terminal results onto Oban's `:ok` / `:snooze` / `:cancel` worker
  return contract. (Task 48)
- `Harness.Worktree` — per-run git worktree lifecycle: `create/2` carves an
  isolated working directory and `harness/<id>` branch out of a target repo so
  concurrent runs never collide; `commit/2` captures the agent's work as a
  commit on that branch; `finish/3` makes the keep-or-teardown decision
  (tear down on success, retain on failure for inspection — configurable);
  `remove/1` is the unconditional teardown. Teardown removes only the working
  directory — the branch and its commits are the run's deliverable.
- `Harness.Worktree.Sweeper` — boot-time orphan reaper. A run that crashes
  before `finish/3` leaves its worktree behind; the sweeper runs once at
  application start, self-discovers parent repos from leftover worktrees, and
  reaps every orphan that is not a deliberately-retained failure.
- Worktree root is configurable via `:harness, :worktree` (`base_dir`,
  `retain_on_failure`, `sweep_on_boot`) and the `HARNESS_WORKTREE_ROOT` env var.
- `Harness.Roadmap` — ingests a task from an rmap roadmap (by id or the next
  pending one) and renders it as a ready-to-run agent prompt. Shells out to the
  `rmap` CLI (`show` / `next` / `delegate`) rather than parsing the roadmap
  itself, keeping rmap the single source of truth. The input half of the loop.
- `Harness.AgentAdapter` behaviour — the contract every headless coding-agent
  adapter implements: a capability declaration, headless-command construction,
  raw-output capture with termination detection, and cancellation. Raw
  passthrough only — no normalized event model. Agents are spawned over an OTP
  port through a `/bin/sh` wrapper that hands them a stdin already at EOF, so a
  headless CLI never stalls peeking for piped input.
- `Harness.AgentAdapter.Claude` — the first concrete adapter: drives Claude Code
  headlessly (`claude -p`, raw `stream-json` output, `--permission-mode
  bypassPermissions` for unattended runs, `--continue` session resume against
  the per-job worktree).
- `Harness.AgentAdapter.Codex` — the second concrete adapter, and the first
  proof the `AgentAdapter` contract is not Claude-shaped: drives Codex
  headlessly (`codex exec` raw `--json` JSONL,
  `--dangerously-bypass-approvals-and-sandbox` for unattended runs,
  `exec resume --last` session resume against the per-job worktree). Codex's
  invocation is structurally unlike Claude's — `exec` is a subcommand and
  resuming swaps in `exec resume` rather than adding a flag — yet it was built
  against the unchanged behaviour and passes the conformance suite unchanged,
  so no abstraction leak was surfaced.
- `Harness.AgentAdapter.Cursor` — the Cursor adapter: drives `cursor-agent -p`
  headlessly (raw `stream-json` output, `--force --trust` for unattended runs on
  a fresh worktree, `--continue` session resume). Passes the conformance suite
  unchanged — the contract held against a third agent with no behaviour leak.
- `Harness.AgentAdapter.Grok` — the Grok Build adapter: drives Grok headlessly
  (`grok -p`, raw `streaming-json` output, `--permission-mode bypassPermissions`
  for unattended runs, `--continue` session resume against the per-job
  worktree). Grok's headless-only extras (`--best-of-n`, `--check`, worktree
  flags) are deferred to the capability registry, not the core behaviour.
  Passes the conformance suite unchanged.
- `Harness.AgentAdapter.Antigravity` — the Antigravity CLI adapter: drives `agy`
  headlessly (`agy -p`, raw output captured verbatim,
  `--dangerously-skip-permissions` for unattended runs, `--continue` session
  resume). Passes the conformance suite unchanged.
- `Harness.AgentAdapter.Driver` — the generic run driver: spawns any adapter,
  captures raw output, and enforces two timeout guards — a total-run budget and
  an idle window reset on every output chunk — so a runaway or wedged run is
  killed. Termination is derived from the process closing or a deadline, never
  the exit code. Returns a `Harness.AgentAdapter.Outcome`; timeouts configurable
  via `:harness, :run`. An `:on_spawn` hook hands the run handle to the caller
  the moment the agent spawns, so a wrapping process can cancel it mid-run.
- `Harness.AgentAdapter.OSProcess` — shared port / OS-process lifecycle helper
  (os-pid lookup, idempotent close, mailbox drain, kill) every adapter reuses.
- `Harness.AgentAdapter.ConformanceCase` — the reusable conformance suite every
  adapter must pass, parameterized by adapter module: it pins the contract for
  invocation, verbatim raw-output capture, termination detection, timeout, and
  adapter-level cancellation. The contract checks are agent-free (synthesized
  port messages, a `/bin/sleep` stand-in); one `:integration`-tagged test drives
  the real agent end to end. The gate Codex and every later adapter (Cursor,
  Grok, Antigravity) are held to — a leak it catches is fixed in the behaviour,
  never patched around in the adapter. Run against every adapter — Claude,
  Codex, Cursor, Grok, Antigravity — and `Harness.FakeAdapter`.
- `Harness.Verification` — the run grader: runs a target project's check stack
  against a worktree and aggregates the results into a `Verdict`. This is how
  harness decides "did the job succeed?" objectively, never from the agent's
  self-reported exit code. Ships an Elixir preset (`mix test.json`,
  `mix dialyzer.json`, credo, doctor, sobelow); the stack is configurable via
  `:harness, :verification`. Each check is spawned over an OTP port with a
  per-check timeout, so a hung check is killed rather than wedging the run. The
  verification half of the loop.
- `Harness.Run` — the supervised run lifecycle: a `:gen_statem` that owns one
  job end to end, moving through `dispatched → running → committing → verifying
  → {done | failed}`. It carves the isolated worktree, dispatches the agent,
  waits for termination, commits the agent's work to the run branch, runs the
  verification stack, and settles on a verdict — the single-agent core loop
  working end to end. A run that produced no diff settles `:no_changes`. Each
  step runs in a monitored task so a crashing step never crashes the run; a
  per-run lifetime budget and `cancel/1` both abort cleanly, SIGKILLing the
  agent; `status/1` exposes live state. A run is graded by the verification
  stack alone, never by the agent's exit code — a run whose agent timed out is
  still verified.
- `Harness.Run.Supervisor` — the `:one_for_one` `DynamicSupervisor` each
  `Harness.Run` starts under as a `:temporary` child, so one run crashing is
  isolated from its siblings and a failed run is never restarted. `start_run/4`
  is the entry point; runs are looked up by id through a `Registry`.
- Autonomous repair loop — a red verification verdict is no longer terminal.
  While repair attempts remain, `Harness.Run` resumes the **same** agent with a
  prompt (`Harness.Run.RepairPrompt`) carrying the failing checks' output,
  re-commits, and re-grades. The objective check stack stays the grader, so the
  agent is repairing rather than self-grading. The loop stops on green, at the
  attempt cap, or on a non-red terminal failure of an attempt — a quota-starved
  agent that produces no diff settles `:no_changes` instead of burning the
  remaining attempts. `repair_attempts` on `Harness.Run.Result` and
  `Harness.Run.Status` reports how many attempts a run made.
- `Harness.Batch` — the batch layer: fans a set of tasks out across supervised
  `Harness.Run` children under a configurable concurrency cap, tolerates partial
  failure (one red or crashed run never aborts the batch), and collects one
  `Harness.Run.Result` per task — in input order — into a `Harness.Batch.Result`.
  A batch is typically an `rmap` bundle or `rmap next-bundle` result.
- `Harness.Run.RetryPolicy` + `Harness.Run.FailureClass` — failure-classified
  retry: a failed run is classified `:transient` (a process crash or flaky
  check — retried with capped exponential backoff), `:quota_exhausted` (a
  subscription agent at its cap — stops retrying that agent at once and marks it
  for fail-over, since the reset window is hours, not a backoff timescale), or
  `:terminal` (a genuine red verdict — never retried). The policy is available
  as a standalone helper (`RetryPolicy.run/2`) and configurable via
  `:harness, :retry_policy`. Wired into `Harness.Batch` (Task 28, below).
- Run lifecycle timeouts and the repair-attempt cap are configurable via
  `:harness, :run` (`lifetime_timeout`, `terminal_linger`,
  `max_repair_attempts`) alongside the existing agent `total_timeout` /
  `idle_timeout`.
- Caller-controlled agent environment — `Harness.AgentAdapter.Invocation` carries
  an `env` map threaded through every adapter's `build_command/1` into the port
  spawn: `%{"KEY" => "value"}` sets a variable, `%{"KEY" => false}` scrubs an
  inherited one (e.g. removing `ANTHROPIC_API_KEY` so `claude` falls back to its
  subscription OAuth). Passed per run via the `:env` opt to `start_run/4`; the
  orchestrator BEAM's own environment is never mutated. The conformance suite
  gates both injection and scrubbing on every adapter.
- `Harness.AgentRules` + `priv/agent_rules/canonical.md` — the canonical,
  harness-owned rule set every dispatched agent receives. A curated filterable
  subset: verification gates (coverage thresholds, dialyzer-zero,
  credo-strict) are deliberately excluded because the verification runner
  enforces them, not prose the agent is trusted to honour.
- `Harness.AgentAdapter.RulesInjection` — per-adapter rule-set injection
  threaded through every adapter's `build_command/1`. Claude uses
  `--append-system-prompt-file`; Codex and Cursor render an ephemeral rule
  file into the run worktree; Grok and Antigravity prompt-prepend (neither
  exposes a system-prompt flag or a native rule file). Two different agents
  dispatched by harness now receive the same canonical rules without any
  hand-maintained per-repo file.
- `Harness.AgentRegistry` — declarative per-adapter capability listing plus
  availability state. `Harness.Batch` and `Harness.Run.Supervisor` gain a
  capability check before dispatch: a run requesting an unsupported
  capability is rejected up front, never mid-run. A quota-exhausted agent is
  marked unavailable and the batch routes its task to another capable
  adapter with headroom; fail-over routing is observable via
  `Harness.Batch.Result` events.
- `Harness.StatusView` + `mix harness.status` — a human-readable fleet view
  (`Harness.StatusView`) that aggregates live `Harness.Run.Status` snapshots
  from `Harness.Run.Supervisor` and unavailable agents from
  `Harness.AgentRegistry`, classifying runs into `IN FLIGHT` / `REPAIRING` /
  `GREEN` / `RED` with the failure reason for red runs and the attempt count
  for runs in repair. `Harness.AgentRegistry.list_unavailable/0` exposes the
  unavailable adapter list, and `Harness.Run.Status` gains a `:reason` field
  so the view can surface why a run settled. The Mix task is a thin
  IO.puts wrapper around `StatusView.snapshot/0` and `StatusView.render/1`.
- `Harness.ResultStore` + `Harness.ResultStore.File` — pluggable result-store
  boundary. `Harness.ResultStore` declares the `record_run/2`, `save_batch/2`,
  `load_batch/2`, `list_run_records/2` callbacks; `Harness.ResultStore.File`
  is the file-backed default, persisting Erlang external terms under a
  configurable root (`~/.harness/results` by default). Persistence is
  best-effort: store errors are logged via `Logger.warning/1` and never crash
  a run or a batch. Configured via `config :harness, :result_store` as
  `module()`, `{module(), keyword()}`, `nil`, or `false` (the last two
  disable persistence).
- `Harness.Run.LogRecord` — structured, queryable per-run-attempt record
  (`agent`, `adapter`, `verdict`, `reason`, `duration_ms`, `repair_attempts`,
  `first_attempt_failed_check_count`, `agent_diff_size`, `failure_cause`,
  `agent_outcome_kind`, `agent_exit_status`, `agent_output`). Emitted by
  `Harness.Run` when a run settles and by `Harness.Batch` when a run crashes
  before delivering a result. Failure causes — including the failing-check
  summary — are reconstructable from the record alone, no live run process
  needed.
- `Harness.Batch.Result` gains a `:batch_id` field. `Harness.Batch.run/4`
  generates one when the caller does not supply it, threads it through
  `Harness.Run`'s state, and persists the aggregate `BatchResult` via
  `ResultStore.save_batch/2` so batches survive process exit. Reloadable
  via `Harness.ResultStore.load_batch/2`.
- `Harness.Run.Result` gains `:first_attempt_failed_check_count` and
  `:agent_diff_size`. The diff size is measured by `Harness.Worktree.diff_size/1`
  (a `git add -A` + `git diff --cached --numstat HEAD` pair) before commit,
  so the count matches what `commit/2` captures.
- `Harness.AuditReview` — HIGH-tier second-grader dispatch wrapper for the
  codified `staged-review:audit-review` skill. `grade_fix/1` dispatches the
  opposite-agent grader (`:claude ↔ :codex` auto-pair; explicit `:grader`
  overrides) via `Harness.AgentAdapter.Driver.run/3` directly — bypassing
  `Harness.Run` and the verification stack on purpose (the grader's *text* IS
  the verdict, not a green/red check). Parses a `<<<VERDICT:APPROVE|REJECT>>>`
  sentinel from the raw transcript with last-match-wins, returning
  `{:ok, %{verdict, outcome, grader}}` for any dispatch that spawned. Synchronous;
  one-shot and read-only. (Task 58)

### Fixed

- `Harness.Batch` no longer crashes with a `MatchError` when every capable
  adapter has been marked unavailable (typically by quota fail-over) mid-batch.
  Queued items that have not yet been dispatched now settle as `:failed`
  `Harness.Run.Result`s with reason `{:no_available_agent, reason}` and emit
  a per-item `{:no_available_agent, task_id, reason}` event on the batch's
  event log instead of orphaning active runs. The reason type on
  `Harness.Run.Result` widens to include `{:no_available_agent, term()}` for
  this terminal state.
- `Harness.Worktree.commit/2` (and `diff_size/1`) no longer commits the harness-injected agent rules into the run branch. `Harness.AgentRules.cleanup_injected_rules/1` removes the Claude / Cursor rule files outright and strips only the harness-injected block from Codex's `AGENTS.md`, preserving legitimate agent edits below the block. (Task 36)
- `Harness.Worktree.commit/2` now asserts the worktree's HEAD still points at its own `harness/<id>` branch (via `rev-parse` + `symbolic-ref` check) before staging. An agent that ran `git switch` or detached HEAD inside the worktree would previously land the commit off-branch and have its deliverable lost at teardown; the run now settles `{:commit_failed, {:head_moved, where}}` cleanly instead. (Task 30)
- `Harness.Batch`'s internal `fill_slots` loop no longer crashes the whole batch when `Harness.Run.Supervisor.start_run/4` returns an error tuple (e.g. duplicate `run_id`, `DynamicSupervisor.start_child/2` failure after adapter selection). The failed item settles `:failed` with the start_run error reason; sibling items in the batch continue to run. (Task 35)
- `Harness.Run.FailureClass.classify/2` correctly classifies quota exhaustion *before* a repair-loop resume can fire. The repair loop previously treated a quota-classified failure as repairable, burning a repair attempt on an agent that physically cannot make progress; the classifier now short-circuits with `:quota_exhausted` so the run settles immediately and routes to fail-over via `Harness.AgentRegistry`. (Task 37)
- `Harness.Run` releases its batch concurrency slot the moment the result is delivered to the subscriber, not after `terminal_linger` expires. Status remains observable through the linger window for late `status/1` callers, but the slot is free for the next item — fixes a multi-second stall on every batch under the previous behaviour. (Task 38)
- `Harness.Run` force-settles `:failed` with reason `:timed_out` when the lifetime budget elapses, even if the agent's `{:run_handle, _}` message never arrived. Previously a hanging `build_command/1` could wedge the run indefinitely; the lifetime timer now fires unconditionally and `force_settle_lifetime/1` replies to any deferred cancel caller before transitioning. (Task 29)
- `Harness.Verification` preset tightened to silence Round-4 false positives without weakening the gate: `sobelow_skip ["CI.System"]` annotations cover the `System.cmd("mix", ...)` invocation in `BaselineFilter.Credo` (literal-only argv, never shell-interpolated), and `:jason` is added to `:dialyzer.plt_add_apps` so dialyzer recognises the new `Jason.decode/1` call site under `plt_add_deps: :apps_direct`. (closeout of Tasks 36 + 43)
- Initial OTP application scaffold with a supervision tree (`Harness.Application`).
- Standard Elixir dev/test tooling stack: Styler (formatter plugin), Credo,
  Dialyxir, Doctor, Sobelow, `ex_unit_json`, `dialyzer_json`, `ex_dna`, `ex_ast`,
  and Reach + Boxart for OTP analysis.
- `descripex` as the agent-facing API dependency.
- `tidewave` + `bandit` for the dev MCP/HTTP surface (Tidewave on port 4016).
- `cli/0` preferred-env wiring for `mix test.json` / `mix dialyzer.json`.
- Dialyzer configured with `plt_add_deps: :apps_direct`; PLTs under `priv/plts/`.
- Project configs: `.doctor.exs`, `.dialyzer_ignore.exs`, `.reach.exs`, `.mcp.json`.
- `Harness.AgentAdapter` — hoisted the byte-identical `classify_message/2`, `terminate/1`, and `--model` argv helper into the behaviour via `use Harness.AgentAdapter` + `defoverridable` (with top-level default providers). A new adapter now implements only `capabilities/0` + `build_command/1` and passes the conformance suite; all 6 existing adapters were updated (duplication removed) and continue to pass unchanged. Added `model_args/1` public helper. (Task 27)
- `Harness.Batch` now dispatches every Run start through `Harness.Run.RetryPolicy.run/2`, so the orchestrator consumes failure classifications natively: transient errors (worktree-create, lock contention) are retried up to the policy's cap, quota classifications halt fan-out for the affected adapter, and exhausted-retry surrender settles the slot as `:failed` with the last classification. The wired-in policy is exposed via `Batch.start_link/1` opts. (Task 28)
- `Harness.Verification.Check` gains an optional `post_process` hook (`{module, function}`) re-graded against the per-run baseline. `Harness.Verification.BaselineFilter.Credo` is the first hook: it runs `git diff --name-only base..HEAD` to scope inherited debt out of credo's `TagTODO` findings, so pre-existing `TODO:` comments no longer red the verification stack on otherwise-clean dispatched work. `Harness.Worktree` now captures `:base_sha` at carve-out (stable for the worktree's lifetime) and `Harness.Verification.run/2` threads `:base_ref` through `post_process_opts`. (Task 43)
- Baseline `.gitignore`, `README.md`, and this changelog.
